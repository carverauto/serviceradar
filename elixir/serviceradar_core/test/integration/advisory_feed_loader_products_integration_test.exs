defmodule ServiceRadar.Inventory.AdvisoryFeeds.LoaderProductsIntegrationTest do
  # These tests deliberately exercise global content-addressed UUID collisions.
  # Serial execution avoids unique-index lock contention between sandbox
  # transactions that intentionally reuse the same IDs.
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Inventory.AdvisoryFeeds.Loader
  alias ServiceRadar.Repo

  @moduletag :integration

  @provider "test-provider"
  @schema "platform"
  @product_id "10000000-0000-8000-8000-000000000001"
  @parent_product_id "10000000-0000-8000-8000-000000000002"
  @product_set_id "20000000-0000-8000-8000-000000000001"

  setup do
    {:ok, feed_key: "loader-products-#{System.unique_integer([:positive])}"}
  end

  test "two advisories reuse one immutable product and product set", %{feed_key: feed_key} do
    records = [record("CVE-2099-1001"), record("CVE-2099-1002")]
    product_id = dump_uuid!(@product_id)
    product_set_id = dump_uuid!(@product_set_id)

    assert {:ok, result} = load(feed_key, records)
    assert result.products_upserted == 1
    assert result.product_sets_upserted == 1
    assert result.assertions_upserted == 2

    assert Repo.aggregate(
             from(product in "advisory_products", where: product.id == ^product_id),
             :count,
             prefix: @schema
           ) == 1

    assert Repo.aggregate(
             from(product_set in "advisory_product_sets",
               where: product_set.id == ^product_set_id
             ),
             :count,
             prefix: @schema
           ) == 1

    assert Repo.aggregate(
             from(assertion in "advisory_package_assertions",
               where: assertion.product_set_ref == ^product_set_id
             ),
             :count,
             prefix: @schema
           ) == 2
  end

  test "a shared definition emitted by an unchanged record is available to a later changed record",
       %{feed_key: feed_key} do
    initial =
      "CVE-2099-2001"
      |> record()
      |> Map.put(:products, [])
      |> Map.put(:product_sets, [])
      |> Map.put(:assertions, [])

    assert {:ok, _result} = load(feed_key, [initial])

    # Simulate the projector's per-run definition suppression order: the first
    # unchanged record carries the definitions, while the later changed record
    # references the set without repeating them.
    unchanged = record("CVE-2099-2001")

    changed =
      "CVE-2099-2002"
      |> record()
      |> Map.put(:products, [])
      |> Map.put(:product_sets, [])

    assert {:ok, result} = load(feed_key, [unchanged, changed])
    assert result.advisories_skipped == 1
    assert result.advisories_upserted == 1
    assert assertion_product_set("assertion-CVE-2099-2002") == @product_set_id
  end

  test "updating an assertion preserves its id and reaps only omitted assertion keys", %{
    feed_key: feed_key
  } do
    cve = "CVE-2099-3001"

    initial =
      record(cve,
        assertions: [
          assertion("stable", cve, "affected"),
          assertion("removed", cve, "affected")
        ]
      )

    assert {:ok, _result} = load(feed_key, [initial])
    original_id = assertion_id("stable")

    replacement =
      cve
      |> record(
        modified_at: "2099-09-02T02:00:00Z",
        projection_digest: String.duplicate("d", 64),
        assertions: [assertion("stable", cve, "fixed")]
      )
      |> Map.put(:products, [])
      |> Map.put(:product_sets, [])

    assert {:ok, result} = load(feed_key, [replacement])
    assert result.assertions_upserted == 1

    assert {^original_id, "fixed"} = assertion_state("stable")
    refute assertion_exists?("removed")
  end

  @tag sandbox: :unboxed, timeout: 120_000
  test "concurrent feeds cannot claim and then overwrite the same assertion key" do
    assertion_key = "ownership-race-#{System.unique_integer([:positive])}"
    feed_keys = ["ownership-a-#{assertion_key}", "ownership-b-#{assertion_key}"]
    parent = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT pg_advisory_xact_lock(hashtextextended('serviceradar:advisory-assertion:' || $1, 0))",
            [assertion_key]
          )

          send(parent, :assertion_lock_held)

          receive do
            :release_assertion_lock -> :ok
          after
            60_000 -> raise "timed out holding assertion ownership test lock"
          end
        end)
      end)

    assert_receive :assertion_lock_held, 10_000

    workers =
      Enum.map(
        [
          {Enum.at(feed_keys, 0), scalar_record("CVE-2099-3101", assertion_key)},
          {Enum.at(feed_keys, 1), scalar_record("CVE-2099-3102", assertion_key)}
        ],
        fn {feed_key, record} ->
          Task.async(fn ->
            try do
              load(feed_key, [record])
            rescue
              error in ArgumentError -> {:ownership_error, Exception.message(error)}
            end
          end)
        end
      )

    try do
      assert wait_for_assertion_lock_waiters(2, 100)
      send(blocker.pid, :release_assertion_lock)

      results = Enum.map(workers, &Task.await(&1, 60_000))
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      assert [{:ownership_error, message}] =
               Enum.filter(results, &match?({:ownership_error, _}, &1))

      assert message =~ "belongs to a different advisory"

      assert Repo.aggregate(
               from(assertion in "advisory_package_assertions",
                 where: assertion.assertion_key == ^assertion_key
               ),
               :count,
               prefix: @schema
             ) == 1
    after
      send(blocker.pid, :release_assertion_lock)
      Enum.each(workers, &Task.shutdown(&1, :brutal_kill))
      Task.shutdown(blocker, :brutal_kill)
      cleanup_unboxed_feeds(feed_keys)
    end
  end

  test "same product UUID with a different full digest aborts the whole generation", %{
    feed_key: feed_key
  } do
    assert {:ok, _result} = load(feed_key, [record("CVE-2099-4001")])

    colliding =
      "CVE-2099-4002"
      |> record()
      |> update_in([:products, Access.at(0), :content_sha256], fn _ ->
        String.duplicate("e", 64)
      end)

    assert_raise ArgumentError, ~r/advisory product ID collision/, fn ->
      load(feed_key, [colliding])
    end

    refute advisory_exists?(feed_key, "CVE-2099-4002")
  end

  test "same product UUID and digest with different canonical fields aborts the generation", %{
    feed_key: feed_key
  } do
    assert {:ok, _result} = load(feed_key, [record("CVE-2099-4501")])

    corrupted_projection =
      "CVE-2099-4502"
      |> record()
      |> update_in([:products, Access.at(0)], fn product ->
        %{product | package_name: "not-starling-fetch"}
      end)

    assert_raise ArgumentError, ~r/advisory product immutable content mismatch/, fn ->
      load(feed_key, [corrupted_projection])
    end

    refute advisory_exists?(feed_key, "CVE-2099-4502")
  end

  test "same product-set UUID with a different full digest aborts the whole generation", %{
    feed_key: feed_key
  } do
    assert {:ok, _result} = load(feed_key, [record("CVE-2099-5001")])

    colliding =
      "CVE-2099-5002"
      |> record()
      |> Map.put(:products, [])
      |> update_in([:product_sets, Access.at(0), :content_sha256], fn _ ->
        String.duplicate("f", 64)
      end)

    assert_raise ArgumentError, ~r/advisory product set ID collision/, fn ->
      load(feed_key, [colliding])
    end

    refute advisory_exists?(feed_key, "CVE-2099-5002")
  end

  test "missing and cyclic parent products abort before any definition is inserted", %{
    feed_key: feed_key
  } do
    missing_parent =
      "CVE-2099-6001"
      |> record()
      |> put_in([:products, Access.at(0), :parent_product_id], @parent_product_id)

    assert_raise ArgumentError, ~r/missing parent product/, fn ->
      load(feed_key, [missing_parent])
    end

    refute product_exists?(@product_id)

    parent =
      product(
        id: @parent_product_id,
        digest: String.duplicate("c", 64),
        name: "parent",
        parent_product_id: @product_id
      )

    cycle =
      update_in(missing_parent, [:products], fn [child] -> [child, parent] end)

    assert_raise ArgumentError, ~r/cyclic parent products/, fn ->
      load(feed_key, [cycle])
    end

    refute product_exists?(@product_id)
    refute product_exists?(@parent_product_id)
  end

  test "parent products are inserted before children even when input UUID order is reversed", %{
    feed_key: feed_key
  } do
    parent =
      product(
        id: @parent_product_id,
        digest: String.duplicate("c", 64),
        name: "starling-suite-source",
        parent_product_id: nil
      )

    child =
      product(parent_product_id: @parent_product_id)

    record =
      "CVE-2099-6501"
      |> record()
      |> Map.put(:products, [child, parent])

    assert {:ok, result} = load(feed_key, [record])
    assert result.products_upserted == 2
    assert product_exists?(@parent_product_id)
    assert product_exists?(@product_id)
  end

  test "missing product-set members and assertion set references abort before promotion", %{
    feed_key: feed_key
  } do
    missing_member =
      "CVE-2099-6601"
      |> record()
      |> Map.put(:products, [])

    assert_raise ArgumentError, ~r/missing advisory product\(s\)/, fn ->
      load(feed_key, [missing_member])
    end

    refute advisory_exists?(feed_key, "CVE-2099-6601")

    missing_set =
      "CVE-2099-6602"
      |> record()
      |> Map.put(:products, [])
      |> Map.put(:product_sets, [])

    assert_raise ArgumentError, ~r/missing advisory product set\(s\)/, fn ->
      load(feed_key, [missing_set])
    end

    refute advisory_exists?(feed_key, "CVE-2099-6602")
  end

  test "a changed projection is rewritten even when the publisher timestamp is unchanged", %{
    feed_key: feed_key
  } do
    cve = "CVE-2099-7001"
    initial = record(cve, title: "old title")
    assert {:ok, _result} = load(feed_key, [initial])

    changed =
      record(cve,
        title: "new title",
        projection_digest: String.duplicate("9", 64)
      )

    assert {:ok, result} = load(feed_key, [changed])
    assert result.advisories_upserted == 1
    assert result.advisories_skipped == 0

    assert Repo.one!(
             from(advisory in "vulnerability_advisories",
               where:
                 advisory.provider == ^@provider and advisory.feed_key == ^feed_key and
                   advisory.source_object_id == ^cve,
               select: advisory.title
             ),
             prefix: @schema
           ) == "new title"
  end

  defp load(feed_key, records) do
    Loader.load_and_finalize(records,
      provider: @provider,
      feed_key: feed_key,
      generation: Loader.next_generation(@provider, feed_key),
      normalization_version: 2,
      completeness: %{
        complete_snapshot?: true,
        source_objects_seen: length(records),
        expected_minimum: 1,
        parse_errors: 0,
        read_errors: 0,
        required_trees: ["records"],
        validation: %{"records" => %{"complete" => true, "count" => length(records)}}
      }
    )
  end

  defp record(cve, opts \\ []) do
    product = product()
    product_set = product_set()

    %{
      advisory: %{
        source_object_id: cve,
        advisory_id: cve,
        cve_id: cve,
        title: Keyword.get(opts, :title, cve),
        description: "fixture",
        modified_at: Keyword.get(opts, :modified_at, "2099-09-02T01:00:00Z"),
        raw: %{},
        metadata: %{
          "normalization_version" => 2,
          "projection_digest" => Keyword.get(opts, :projection_digest, String.duplicate("8", 64))
        }
      },
      coordinates: [],
      products: [product],
      product_sets: [product_set],
      assertions: Keyword.get(opts, :assertions, [assertion("assertion-#{cve}", cve, "affected")])
    }
  end

  defp product(opts \\ []) do
    id = Keyword.get(opts, :id, @product_id)
    name = Keyword.get(opts, :name, "starling-fetch")

    %{
      id: id,
      content_sha256: Keyword.get(opts, :digest, String.duplicate("a", 64)),
      lookup_key: "30000000-0000-8000-8000-000000000001",
      normalization_version: 2,
      package_type: "deb",
      namespace: "ubuntu",
      package_name: name,
      package_version: "3.2.1-1ubuntu99.7+fixture1",
      release: "test-release",
      release_channel: "fixture",
      architecture: "amd64",
      source_package: "starling-suite",
      source_version: "3.2.1-1ubuntu99.7+fixture1",
      canonical_purl:
        "pkg:deb/ubuntu/#{name}@3.2.1-1ubuntu99.7%2Bfixture1?arch=amd64&distro=test-release",
      product_scope: "binary",
      parent_product_id: Keyword.get(opts, :parent_product_id),
      qualifiers: %{"arch" => "amd64", "distro" => "test-release"},
      metadata: %{}
    }
  end

  defp product_set do
    %{
      id: @product_set_id,
      content_sha256: String.duplicate("b", 64),
      normalization_version: 2,
      product_ids: [@product_id],
      product_count: 1,
      canonical_size_bytes: 64,
      metadata: %{}
    }
  end

  defp scalar_record(cve, assertion_key) do
    scalar_assertion =
      assertion_key
      |> assertion(cve, "affected")
      |> Map.put(:assertion_shape, "scalar")
      |> Map.put(:product_set_ref, nil)

    cve
    |> record(assertions: [scalar_assertion])
    |> Map.put(:products, [])
    |> Map.put(:product_sets, [])
  end

  defp wait_for_assertion_lock_waiters(expected, attempts) do
    %{rows: [[count]]} =
      Repo.query!("""
      SELECT count(*)
      FROM pg_stat_activity
      WHERE wait_event_type = 'Lock'
        AND wait_event = 'advisory'
        AND query LIKE '%serviceradar:advisory-assertion:%'
      """)

    cond do
      count >= expected ->
        true

      attempts > 0 ->
        Process.sleep(20)
        wait_for_assertion_lock_waiters(expected, attempts - 1)

      true ->
        false
    end
  end

  defp cleanup_unboxed_feeds(feed_keys) do
    Repo.delete_all(
      from(presence in "advisory_feed_source_presence",
        where: presence.provider == ^@provider and presence.feed_key in ^feed_keys
      ),
      prefix: @schema
    )

    Repo.delete_all(
      from(advisory in "vulnerability_advisories",
        where: advisory.provider == ^@provider and advisory.feed_key in ^feed_keys
      ),
      prefix: @schema
    )
  end

  defp assertion(key, cve, disposition) do
    %{
      assertion_key: key,
      cve_id: cve,
      authority: "canonical",
      source_kind: "ubuntu_osv",
      source_timestamp: "2099-09-02T01:00:00Z",
      assertion_shape: "product_set",
      product_set_ref: @product_set_id,
      statement_fingerprint: String.duplicate("7", 64),
      package_type: "deb",
      namespace: "ubuntu",
      release: "test-release",
      release_channel: "fixture",
      product_scope: "binary",
      version_scheme: "deb",
      disposition: disposition,
      validation: %{},
      raw: %{},
      metadata: %{}
    }
  end

  defp assertion_id(key) do
    Repo.one!(
      from(assertion in "advisory_package_assertions",
        where: assertion.assertion_key == ^key,
        select: assertion.id
      ),
      prefix: @schema
    )
  end

  defp assertion_state(key) do
    Repo.one!(
      from(assertion in "advisory_package_assertions",
        where: assertion.assertion_key == ^key,
        select: {assertion.id, assertion.disposition}
      ),
      prefix: @schema
    )
  end

  defp assertion_product_set(key) do
    Repo.one!(
      from(assertion in "advisory_package_assertions",
        where: assertion.assertion_key == ^key,
        select: type(assertion.product_set_ref, :binary_id)
      ),
      prefix: @schema
    )
  end

  defp assertion_exists?(key) do
    Repo.exists?(
      from(assertion in "advisory_package_assertions", where: assertion.assertion_key == ^key),
      prefix: @schema
    )
  end

  defp advisory_exists?(feed_key, source_object_id) do
    Repo.exists?(
      from(advisory in "vulnerability_advisories",
        where:
          advisory.provider == ^@provider and advisory.feed_key == ^feed_key and
            advisory.source_object_id == ^source_object_id
      ),
      prefix: @schema
    )
  end

  defp product_exists?(id) do
    id = dump_uuid!(id)

    Repo.exists?(from(product in "advisory_products", where: product.id == ^id),
      prefix: @schema
    )
  end

  defp dump_uuid!(uuid) do
    {:ok, dumped} = Ecto.UUID.dump(uuid)
    dumped
  end
end
