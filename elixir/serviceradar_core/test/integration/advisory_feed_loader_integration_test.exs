defmodule ServiceRadar.Inventory.AdvisoryFeeds.LoaderIntegrationTest do
  @moduledoc """
  Round-trip regression tests for the advisory-feed skip guard.

  These MUST hit a real database. The guard compares the incoming `modified_at`
  against a value read back out of Postgres, and the bug it protects against
  only exists on that boundary: `modified_at` is a `timestamp without time zone`
  column read through a schemaless query, so Postgres returns a
  `%NaiveDateTime{}` while the parsed feed value is a `%DateTime{}`.

  A pure unit test that hand-builds the "existing" map with `~U[...]` cannot see
  that — which is exactly how the original defect shipped and went on to write
  ~5.9 TB of WAL re-upserting an unchanged corpus every 6 hours.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker
  alias ServiceRadar.Inventory.AdvisoryFeeds.Loader
  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Nvd
  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Ubuntu
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.AddAdvisoryPackageAssertionHistory

  if !Code.ensure_loaded?(AddAdvisoryPackageAssertionHistory) do
    Code.require_file(
      Path.expand(
        "../../priv/repo/migrations/20260902235600_add_advisory_package_assertion_history.exs",
        __DIR__
      )
    )
  end

  @moduletag :integration

  @provider "test-provider"
  @schema "platform"
  @ubuntu_fixtures Path.expand("../support/fixtures/advisory_feeds/ubuntu", __DIR__)
  @ubuntu_osv_digest String.duplicate("a", 64)
  @ubuntu_vex_digest String.duplicate("b", 64)

  setup context do
    feed_key = "loader-itest-#{System.unique_integer([:positive])}"

    if context[:sandbox] == :unboxed do
      on_exit(fn -> cleanup_unboxed_feed!(feed_key) end)
    end

    {:ok, feed_key: feed_key}
  end

  defp record(id, modified_at, opts \\ []) do
    %{
      advisory: %{
        source_object_id: id,
        advisory_id: id,
        cve_id: id,
        title: Keyword.get(opts, :title, "title #{id}"),
        description: "desc",
        severity: "high",
        modified_at: modified_at,
        raw: %{"id" => id}
      },
      coordinates: Keyword.get(opts, :coordinates, [coordinate("product-#{id}")]),
      assertions: Keyword.get(opts, :assertions, [])
    }
  end

  defp coordinate(product) do
    %{
      coordinate_type: "cpe",
      value: "cpe:2.3:a:vendor:#{product}:1.0:*:*:*:*:*:*:*",
      cpe_part: "a",
      cpe_vendor: "vendor",
      cpe_product: product,
      cpe_version: "1.0",
      metadata: %{}
    }
  end

  defp assertion(key, cve_id, binary_package) do
    %{
      assertion_key: key,
      cve_id: cve_id,
      authority: "test-authority",
      source_kind: "test",
      package_type: "deb",
      namespace: "ubuntu",
      release: "noble",
      binary_package: binary_package,
      version_scheme: "deb",
      disposition: "affected"
    }
  end

  defp fixture_vex_assertion(cve_id, disposition) do
    "synthetic-vex-starforge"
    |> assertion(cve_id, "starforge-cli")
    |> Map.merge(%{
      authority: "synthetic-fixture-authority",
      source_kind: "ubuntu_openvex",
      source_timestamp: ~U[2099-04-05 06:07:08Z],
      assertion_shape: "scalar",
      product_scope: "binary",
      source_package: "starforge",
      architecture: "amd64",
      package_purl: "pkg:deb/ubuntu/starforge-cli@7:42.0-0ubuntu1.1?arch=amd64&distro=noble",
      disposition: disposition,
      justification: "vulnerable_code_not_present",
      status_text: disposition,
      raw: %{
        "reference" => "https://vex.example.invalid/#{cve_id}",
        "status" => disposition
      },
      metadata: %{"provenance" => "synthetic-openvex-fixture"}
    })
  end

  defp assertion_history_hashes(feed_key) do
    Repo.all(
      from(history in "advisory_package_assertion_history",
        where: history.provider == ^@provider and history.feed_key == ^feed_key,
        select: history.content_sha256,
        order_by: history.content_sha256
      ),
      prefix: @schema
    )
  end

  # NVD emits no UTC offset, so this is the shape the real parser sees.
  @records [
    {"ITEST-CVE-0001", "2024-01-15T12:34:56.123"},
    {"ITEST-CVE-0002", "2024-02-20T01:02:03.000"},
    {"ITEST-CVE-0003", "2024-03-25T23:59:59.999"}
  ]

  defp load_generation(feed_key, records) do
    generation = Loader.next_generation(@provider, feed_key)
    completeness = complete_snapshot(length(records))

    result =
      Loader.load_stream(records,
        provider: @provider,
        feed_key: feed_key,
        generation: generation,
        completeness: completeness
      )

    {result, generation}
  end

  defp load(feed_key, records) do
    generation = Loader.next_generation(@provider, feed_key)

    assert {:ok, result} =
             Loader.load_and_finalize(records,
               provider: @provider,
               feed_key: feed_key,
               generation: generation,
               completeness: complete_snapshot(length(records))
             )

    {result, generation}
  end

  defp complete_snapshot(count, overrides \\ %{}) do
    Map.merge(
      %{
        complete_snapshot?: true,
        source_objects_seen: count,
        expected_minimum: 1,
        parse_errors: 0,
        read_errors: 0,
        required_trees: ["records"],
        validation: %{"records" => %{"complete" => true, "count" => count}}
      },
      overrides
    )
  end

  defp drain_assertion_archive_queries(acc) do
    receive do
      {:assertion_archive_query, query} -> drain_assertion_archive_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp history_cves(feed_key) do
    Repo.all(
      from(history in "advisory_package_assertion_history",
        where: history.provider == ^@provider and history.feed_key == ^feed_key,
        order_by: history.cve_id,
        select: history.cve_id
      ),
      prefix: @schema
    )
  end

  defp wait_for_backend_lock(backend_pid, attempts \\ 100)

  defp wait_for_backend_lock(_backend_pid, 0), do: false

  defp wait_for_backend_lock(backend_pid, attempts) do
    case Repo.query!(
           "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
           [backend_pid]
         ).rows do
      [["Lock"]] ->
        true

      _other ->
        Process.sleep(10)
        wait_for_backend_lock(backend_pid, attempts - 1)
    end
  end

  defp cleanup_unboxed_feed!(feed_key) do
    Repo.delete_all(
      from(history in "advisory_package_assertion_history",
        where: history.provider == ^@provider and history.feed_key == ^feed_key
      ),
      prefix: @schema
    )

    Repo.delete_all(
      from(presence in "advisory_feed_source_presence",
        where: presence.provider == ^@provider and presence.feed_key == ^feed_key
      ),
      prefix: @schema
    )

    Repo.delete_all(
      from(advisory in "vulnerability_advisories",
        where: advisory.provider == ^@provider and advisory.feed_key == ^feed_key
      ),
      prefix: @schema
    )

    :ok
  end

  defp read_ubuntu_fixture(relative) do
    @ubuntu_fixtures
    |> Path.join(relative)
    |> File.read!()
    |> Jason.decode!()
  end

  defp all_records, do: Enum.map(@records, fn {id, m} -> record(id, m) end)

  defp live_count(feed_key) do
    Repo.aggregate(
      from(a in "vulnerability_advisories",
        where: a.provider == ^@provider and a.feed_key == ^feed_key and a.current == true
      ),
      :count,
      prefix: @schema
    )
  end

  defp updated_ats(feed_key) do
    Repo.all(
      from(a in "vulnerability_advisories",
        where: a.provider == ^@provider and a.feed_key == ^feed_key,
        select: {a.source_object_id, a.updated_at},
        order_by: a.source_object_id
      ),
      prefix: @schema
    )
  end

  defp stored_coordinates(feed_key) do
    Repo.all(
      from(c in "advisory_coordinates",
        where: c.provider == ^@provider and c.feed_key == ^feed_key,
        select: {c.cpe_product, c.metadata},
        order_by: c.cpe_product
      ),
      prefix: @schema
    )
  end

  defp stored_content_hashes(feed_key) do
    Repo.all(
      from(a in "vulnerability_advisories",
        where: a.provider == ^@provider and a.feed_key == ^feed_key,
        select: a.content_hash,
        order_by: a.source_object_id
      ),
      prefix: @schema
    )
  end

  defp coordinate_updated_ats(feed_key) do
    Repo.all(
      from(c in "advisory_coordinates",
        where: c.provider == ^@provider and c.feed_key == ^feed_key,
        select: {c.value, c.updated_at},
        order_by: c.value
      ),
      prefix: @schema
    )
  end

  defp presence_exists?(feed_key, generation, source_object_id) do
    Repo.exists?(
      from(p in "advisory_feed_source_presence",
        where:
          p.provider == ^@provider and p.feed_key == ^feed_key and
            p.generation == ^generation and p.source_object_id == ^source_object_id
      ),
      prefix: @schema
    )
  end

  defp presence_generations(feed_key) do
    Repo.all(
      from(p in "advisory_feed_source_presence",
        where: p.provider == ^@provider and p.feed_key == ^feed_key,
        distinct: true,
        select: p.generation,
        order_by: [asc: p.generation]
      ),
      prefix: @schema
    )
  end

  defp current_source_ids(feed_key) do
    Repo.all(
      from(a in "vulnerability_advisories",
        where: a.provider == ^@provider and a.feed_key == ^feed_key and a.current == true,
        select: a.source_object_id,
        order_by: a.source_object_id
      ),
      prefix: @schema
    )
  end

  defp advisory_id(feed_key, source_object_id) do
    Repo.one!(
      from(a in "vulnerability_advisories",
        where:
          a.provider == ^@provider and a.feed_key == ^feed_key and
            a.source_object_id == ^source_object_id,
        select: a.id
      ),
      prefix: @schema
    )
  end

  defp child_values(feed_key, source_object_id) do
    advisory_ref = advisory_id(feed_key, source_object_id)

    coordinates =
      Repo.all(
        from(c in "advisory_coordinates",
          where: c.advisory_ref == ^advisory_ref,
          select: c.value,
          order_by: c.value
        ),
        prefix: @schema
      )

    assertions =
      Repo.all(
        from(a in "advisory_package_assertions",
          where: a.advisory_ref == ^advisory_ref,
          select: a.assertion_key,
          order_by: a.assertion_key
        ),
        prefix: @schema
      )

    {coordinates, assertions}
  end

  test "an unchanged source object records presence without rewriting advisory or coordinate content",
       %{
         feed_key: feed_key
       } do
    {first, _gen} = load(feed_key, all_records())

    assert first.advisories_upserted == 3
    assert first.advisories_skipped == 0
    assert live_count(feed_key) == 3

    advisory_before = updated_ats(feed_key)
    coordinate_before = coordinate_updated_ats(feed_key)

    {second, generation} = load(feed_key, all_records())

    # THE regression assertion. Before the fix this was skipped: 0, upserted: 3.
    assert second.advisories_skipped == 3,
           "skip guard is inert: the whole corpus was rewritten on an unchanged run"

    assert second.advisories_upserted == 0
    assert second.coordinates_upserted == 0
    assert second.assertions_upserted == 0
    assert second.source_objects_seen == 3
    assert second.parse_errors == 0

    for {source_object_id, _modified_at} <- @records do
      assert presence_exists?(feed_key, generation, source_object_id)
    end

    assert updated_ats(feed_key) == advisory_before
    assert coordinate_updated_ats(feed_key) == coordinate_before
    assert live_count(feed_key) == 3
  end

  test "timestamp feeds leave the unused content hash empty", %{feed_key: feed_key} do
    {result, _gen} = load(feed_key, all_records())

    assert result.advisories_upserted == 3

    hashes =
      Repo.all(
        from(a in "vulnerability_advisories",
          where: a.provider == ^@provider and a.feed_key == ^feed_key,
          select: a.content_hash,
          order_by: a.source_object_id
        ),
        prefix: @schema
      )

    assert hashes == [nil, nil, nil]
  end

  test "an unchanged NVD timestamp is reprojected once when the expression version advances", %{
    feed_key: feed_key
  } do
    source_object_id = "ITEST-CVE-NVD-EXPRESSION-VERSION"
    modified_at = "2024-01-15T12:34:56.123"

    load_version = fn version ->
      normalized =
        source_object_id
        |> record(modified_at)
        |> put_in([:advisory, :metadata], %{"normalization_version" => version})

      generation = Loader.next_generation(@provider, feed_key)

      assert {:ok, result} =
               Loader.load_and_finalize([normalized],
                 provider: @provider,
                 feed_key: feed_key,
                 generation: generation,
                 normalization_version: version,
                 completeness: complete_snapshot(1)
               )

      result
    end

    assert %{advisories_upserted: 1, advisories_skipped: 0} = load_version.(1)

    assert %{advisories_upserted: 1, advisories_skipped: 0} =
             load_version.(Nvd.normalization_version())

    assert %{advisories_upserted: 0, advisories_skipped: 1} =
             load_version.(Nvd.normalization_version())

    assert %{normalization_version: 2} =
             Loader.existing_advisory_state(@provider, feed_key)[source_object_id]
  end

  test "existing_modified_at/2 returns values the guard can compare", %{feed_key: feed_key} do
    load(feed_key, all_records())

    existing = Loader.existing_modified_at(@provider, feed_key)

    assert map_size(existing) == 3

    # type/2 must load these as DateTime, not the raw NaiveDateTime Postgrex
    # hands back for a `timestamp without time zone` column.
    for {_id, value} <- existing do
      assert %DateTime{} = value
    end

    # And every record must actually match itself.
    for rec <- all_records() do
      assert Loader.unchanged_advisory?(rec, existing)
    end
  end

  test "a genuinely changed advisory is still rewritten", %{feed_key: feed_key} do
    load(feed_key, all_records())

    changed =
      Enum.map([{"ITEST-CVE-0001", "2024-06-01T00:00:00.000"} | tl(@records)], fn {id, m} ->
        record(id, m)
      end)

    {result, _gen} = load(feed_key, changed)

    assert result.advisories_upserted == 1
    assert result.advisories_skipped == 2
    assert live_count(feed_key) == 3
  end

  test "KEV hashes skip unchanged records and backfill legacy rows" do
    feed_key = "cisa-kev"
    record = kev_record()

    {first, _gen} = load(feed_key, [record])
    assert first.advisories_upserted == 1
    assert first.advisories_skipped == 0
    assert live_count(feed_key) == 1

    before = updated_ats(feed_key)

    {second, _gen} = load(feed_key, [record])
    assert second.advisories_upserted == 0
    assert second.advisories_skipped == 1
    assert updated_ats(feed_key) == before

    changed = put_in(record, [:advisory, :description], "Changed KEV description")
    {third, _gen} = load(feed_key, [changed])
    assert third.advisories_upserted == 1
    assert third.advisories_skipped == 0

    {1, _} =
      Repo.update_all(
        from(a in "vulnerability_advisories",
          where: a.provider == ^@provider and a.feed_key == ^feed_key
        ),
        [set: [content_hash: nil]],
        prefix: @schema
      )

    {legacy_backfill, _gen} = load(feed_key, [changed])
    assert legacy_backfill.advisories_upserted == 1
    assert legacy_backfill.advisories_skipped == 0

    {after_backfill, _gen} = load(feed_key, [changed])
    assert after_backfill.advisories_upserted == 0
    assert after_backfill.advisories_skipped == 1
  end

  test "KEV duplicate coordinates persist one canonical winner regardless of input order" do
    feed_key = "cisa-kev"

    {first, _gen} = load(feed_key, [duplicate_coordinate_kev_record()])
    assert first.advisories_upserted == 1
    assert first.coordinates_upserted == 1

    assert [first_hash] = stored_content_hashes(feed_key)
    assert first_hash =~ ~r/^[0-9a-f]{64}$/

    assert [{"alpha", %{"match_criteria_id" => "alternate-coordinate"}}] ==
             stored_coordinates(feed_key)

    {second, _gen} = load(feed_key, [duplicate_coordinate_kev_record(reverse?: true)])
    assert second.advisories_upserted == 0
    assert second.advisories_skipped == 1
    assert stored_content_hashes(feed_key) == [first_hash]

    assert [{"alpha", %{"match_criteria_id" => "alternate-coordinate"}}] ==
             stored_coordinates(feed_key)
  end

  test "changed advisories replace their complete coordinate and assertion sets", %{
    feed_key: feed_key
  } do
    source_object_id = "ITEST-CVE-REPLACE"

    initial =
      record(source_object_id, "2024-01-01T00:00:00Z",
        coordinates: [coordinate("old-a"), coordinate("old-b")],
        assertions: [
          assertion("assertion-old-a", source_object_id, "old-a"),
          assertion("assertion-old-b", source_object_id, "old-b")
        ]
      )

    {first, _generation} = load(feed_key, [initial])
    original_advisory_id = advisory_id(feed_key, source_object_id)

    assert first.coordinates_upserted == 2
    assert first.assertions_upserted == 2

    changed =
      record(source_object_id, "2024-02-01T00:00:00Z",
        coordinates: [coordinate("new")],
        assertions: [
          assertion("assertion-new", source_object_id, "new"),
          assertion("assertion-new", source_object_id, "new")
        ]
      )

    {second, _generation} = load(feed_key, [changed])

    assert advisory_id(feed_key, source_object_id) == original_advisory_id
    assert second.coordinates_upserted == 1
    assert second.assertions_upserted == 1

    assert child_values(feed_key, source_object_id) ==
             {[coordinate("new").value], ["assertion-new"]}
  end

  test "a changed source object with empty child lists explicitly withdraws old children", %{
    feed_key: feed_key
  } do
    source_object_id = "ITEST-CVE-EMPTY"

    initial =
      record(source_object_id, "2024-01-01T00:00:00Z",
        coordinates: [coordinate("old")],
        assertions: [assertion("assertion-old", source_object_id, "old")]
      )

    load(feed_key, [initial])

    replacement =
      record(source_object_id, "2024-02-01T00:00:00Z", coordinates: [], assertions: [])

    load(feed_key, [replacement])

    assert child_values(feed_key, source_object_id) == {[], []}
  end

  test "invalid preflight rejects changed content before it can overwrite the last complete row",
       %{
         feed_key: feed_key
       } do
    source_object_id = "ITEST-CVE-PREFLIGHT"

    initial =
      record(source_object_id, "2024-01-01T00:00:00Z",
        title: "last complete",
        coordinates: [coordinate("last-complete")],
        assertions: [assertion("assertion-last-complete", source_object_id, "last-complete")]
      )

    load(feed_key, [initial])
    original_id = advisory_id(feed_key, source_object_id)
    original_children = child_values(feed_key, source_object_id)
    original_timestamps = {updated_ats(feed_key), coordinate_updated_ats(feed_key)}

    changed =
      record(source_object_id, "2024-02-01T00:00:00Z",
        title: "partial replacement",
        coordinates: [coordinate("partial")],
        assertions: [assertion("assertion-partial", source_object_id, "partial")]
      )

    generation = Loader.next_generation(@provider, feed_key)

    assert {:error, {:incomplete_snapshot, [_ | _]}} =
             Loader.load_stream([changed],
               provider: @provider,
               feed_key: feed_key,
               generation: generation,
               completeness: complete_snapshot(1, %{parse_errors: 1})
             )

    assert advisory_id(feed_key, source_object_id) == original_id
    assert child_values(feed_key, source_object_id) == original_children
    assert {updated_ats(feed_key), coordinate_updated_ats(feed_key)} == original_timestamps
  end

  test "retained-count rejection preserves the prior complete generation", %{
    feed_key: feed_key
  } do
    initial =
      for index <- 1..10 do
        record("ITEST-CVE-RETENTION-#{index}", "2024-01-01T00:00:00Z",
          coordinates: [coordinate("retention-#{index}")]
        )
      end

    load(feed_key, initial)
    prior_source_ids = current_source_ids(feed_key)
    generation = Loader.next_generation(@provider, feed_key)
    observed = Enum.take(initial, 8)

    completeness =
      complete_snapshot(length(observed), %{
        expected_minimum: 9,
        retained_count_floor: %{
          "policy" => "prior_complete_retention",
          "prior_count" => 10,
          "minimum_count" => 9,
          "retained_percent" => 90,
          "observed_count" => 8
        }
      })

    assert {:error,
            {:incomplete_snapshot,
             [
               {:below_expected_minimum,
                %{
                  "prior_count" => 10,
                  "observed_count" => 8,
                  "minimum_count" => 9
                }}
             ]}} =
             Loader.load_and_finalize(observed,
               provider: @provider,
               feed_key: feed_key,
               generation: generation,
               completeness: completeness
             )

    assert current_source_ids(feed_key) == prior_source_ids

    refute Enum.any?(initial, fn item ->
             presence_exists?(feed_key, generation, item.advisory.source_object_id)
           end)
  end

  test "a later chunk failure rolls back earlier changed content in the same run", %{
    feed_key: feed_key
  } do
    source_object_id = "ITEST-CVE-ROLLBACK"

    initial =
      record(source_object_id, "2024-01-01T00:00:00Z",
        coordinates: [coordinate("last-complete")],
        assertions: [assertion("assertion-last-complete", source_object_id, "last-complete")]
      )

    load(feed_key, [initial])
    original_id = advisory_id(feed_key, source_object_id)
    original_children = child_values(feed_key, source_object_id)
    original_timestamps = {updated_ats(feed_key), coordinate_updated_ats(feed_key)}

    changed =
      record(source_object_id, "2024-02-01T00:00:00Z",
        coordinates: [coordinate("would-leak")],
        assertions: [assertion("assertion-would-leak", source_object_id, "would-leak")]
      )

    invalid_record =
      "ITEST-CVE-INVALID"
      |> record("2024-02-01T00:00:00Z")
      |> put_in([:advisory, :source_object_id], nil)

    generation = Loader.next_generation(@provider, feed_key)

    assert_raise Postgrex.Error, fn ->
      Loader.load_and_finalize([changed, invalid_record],
        provider: @provider,
        feed_key: feed_key,
        generation: generation,
        chunk_size: 1,
        completeness: complete_snapshot(2)
      )
    end

    assert advisory_id(feed_key, source_object_id) == original_id
    assert child_values(feed_key, source_object_id) == original_children
    assert {updated_ats(feed_key), coordinate_updated_ats(feed_key)} == original_timestamps
  end

  test "retains superseded Ubuntu assertion snapshots across generations", %{
    feed_key: feed_key
  } do
    cve_id = "CVE-2099-424250"

    initial =
      record(cve_id, ~U[2099-04-05 06:07:08Z],
        assertions: [fixture_vex_assertion(cve_id, "not_affected")]
      )

    {_first_result, first_generation} = load(feed_key, [initial])

    assert %{generation: ^first_generation, disposition: "not_affected"} =
             Repo.one!(
               from(assertion in "advisory_package_assertions",
                 where:
                   assertion.provider == ^@provider and assertion.feed_key == ^feed_key and
                     assertion.source_kind == "ubuntu_openvex",
                 select: %{
                   generation: assertion.generation,
                   disposition: assertion.disposition
                 }
               ),
               prefix: @schema
             )

    # Simulate an upgrade where the current assertion predates the new history
    # table. The next replacement must archive the stored generation before it
    # overwrites the authoritative row.
    assert {1, nil} =
             Repo.delete_all(
               from(history in "advisory_package_assertion_history",
                 where: history.provider == ^@provider and history.feed_key == ^feed_key
               ),
               prefix: @schema
             )

    changed =
      initial
      |> put_in([:advisory, :modified_at], ~U[2099-04-06 07:08:09Z])
      |> Map.put(:assertions, [fixture_vex_assertion(cve_id, "affected")])

    handler_id = {__MODULE__, :assertion_archive_queries, feed_key}
    test_pid = self()
    telemetry_event = Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :telemetry.attach(
      handler_id,
      telemetry_event,
      fn _event, _measurements, metadata, %{test_pid: test_pid} ->
        send(test_pid, {:assertion_archive_query, metadata.query})
      end,
      %{test_pid: test_pid}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {_second_result, second_generation} = load(feed_key, [changed])
    archive_queries = drain_assertion_archive_queries([])

    assert Enum.any?(archive_queries, fn query ->
             String.contains?(query, "INSERT INTO platform.advisory_package_assertion_history") and
               String.contains?(query, "FROM platform.advisory_package_assertions")
           end)

    refute Enum.any?(archive_queries, fn query ->
             normalized = query |> String.trim_leading() |> String.upcase()

             String.starts_with?(normalized, "SELECT") and
               String.contains?(query, "advisory_package_assertions") and
               String.contains?(query, "source_timestamp") and
               String.contains?(query, "affected_versions")
           end)

    assert %{generation: ^second_generation, disposition: "affected"} =
             Repo.one!(
               from(assertion in "advisory_package_assertions",
                 where:
                   assertion.provider == ^@provider and assertion.feed_key == ^feed_key and
                     assertion.source_kind == "ubuntu_openvex",
                 select: %{
                   generation: assertion.generation,
                   disposition: assertion.disposition
                 }
               ),
               prefix: @schema
             )

    assert [
             %{generation: ^first_generation, disposition: "not_affected", snapshot: first},
             %{generation: ^second_generation, disposition: "affected", snapshot: second}
           ] =
             Repo.all(
               from(history in "advisory_package_assertion_history",
                 where:
                   history.provider == ^@provider and history.feed_key == ^feed_key and
                     history.source_kind == "ubuntu_openvex",
                 order_by: history.generation,
                 select: %{
                   generation: history.generation,
                   disposition: history.disposition,
                   snapshot: history.snapshot
                 }
               ),
               prefix: @schema
             )

    assert first["raw"]["status"] == "not_affected"
    assert second["raw"]["status"] == "affected"
  end

  test "same-generation assertion retry does not duplicate immutable history", %{
    feed_key: feed_key
  } do
    cve_id = "CVE-2099-424251"

    normalized_record =
      record(cve_id, ~U[2099-04-05 06:07:08Z],
        assertions: [fixture_vex_assertion(cve_id, "not_affected")]
      )

    generation = Loader.next_generation(@provider, feed_key)

    first_opts = [
      provider: @provider,
      feed_key: feed_key,
      generation: generation,
      now: ~U[2099-04-06 07:08:09Z],
      existing_state: %{},
      completeness: complete_snapshot(1)
    ]

    retry_opts = Keyword.put(first_opts, :now, ~U[2099-04-06 07:13:09Z])

    assert {:ok, first_result} = Loader.load_and_finalize([normalized_record], first_opts)
    assert first_result.assertions_upserted == 1
    assert [first_hash] = assertion_history_hashes(feed_key)
    assert byte_size(first_hash) == 64

    # Simulate the table being introduced after this current assertion already
    # existed. The migration backfill must capture it once, remain idempotent,
    # and use the same semantic hash as the runtime archival path.
    assert {1, nil} =
             Repo.delete_all(
               from(history in "advisory_package_assertion_history",
                 where: history.provider == ^@provider and history.feed_key == ^feed_key
               ),
               prefix: @schema
             )

    assert %{num_rows: 1} = Repo.query!(AddAdvisoryPackageAssertionHistory.backfill_sql())
    assert %{num_rows: 0} = Repo.query!(AddAdvisoryPackageAssertionHistory.backfill_sql())
    assert [^first_hash] = assertion_history_hashes(feed_key)

    assert {:ok, retry_result} = Loader.load_and_finalize([normalized_record], retry_opts)
    assert retry_result.assertions_upserted == 1
    assert [^first_hash] = assertion_history_hashes(feed_key)
  end

  test "reaping demoted advisories archives assertions server-side before cascade deletion", %{
    feed_key: feed_key
  } do
    cve_id = "CVE-2099-424252"

    normalized_record =
      record(cve_id, ~U[2099-04-05 06:07:08Z],
        assertions: [fixture_vex_assertion(cve_id, "not_affected")]
      )

    {_result, generation} = load(feed_key, [normalized_record])

    assert {1, nil} =
             Repo.update_all(
               from(advisory in "vulnerability_advisories",
                 where: advisory.provider == ^@provider and advisory.feed_key == ^feed_key
               ),
               [set: [current: false]],
               prefix: @schema
             )

    assert {1, nil} =
             Repo.delete_all(
               from(history in "advisory_package_assertion_history",
                 where: history.provider == ^@provider and history.feed_key == ^feed_key
               ),
               prefix: @schema
             )

    assert :ok = Loader.reap_old_generations(@provider, feed_key, generation + 2)
    assert [hash] = assertion_history_hashes(feed_key)
    assert byte_size(hash) == 64

    refute Repo.exists?(
             from(advisory in "vulnerability_advisories",
               where: advisory.provider == ^@provider and advisory.feed_key == ^feed_key
             ),
             prefix: @schema
           )

    refute Repo.exists?(
             from(assertion in "advisory_package_assertions",
               where: assertion.provider == ^@provider and assertion.feed_key == ^feed_key
             ),
             prefix: @schema
           )

    assert :ok = Loader.reap_old_generations(@provider, feed_key, generation + 2)
    assert [^hash] = assertion_history_hashes(feed_key)
  end

  @tag sandbox: :unboxed
  test "reaping cannot delete an advisory demoted after its locked archive snapshot", %{
    feed_key: feed_key
  } do
    first_cve = "CVE-2099-424253"
    second_cve = "CVE-2099-424254"

    records = [
      record(first_cve, ~U[2099-04-05 06:07:08Z],
        assertions: [
          first_cve
          |> fixture_vex_assertion("not_affected")
          |> Map.put(:assertion_key, "synthetic-vex-starforge-first")
        ]
      ),
      record(second_cve, ~U[2099-04-05 06:07:08Z],
        assertions: [
          second_cve
          |> fixture_vex_assertion("not_affected")
          |> Map.put(:assertion_key, "synthetic-vex-starforge-second")
        ]
      )
    ]

    {_result, generation} = load(feed_key, records)

    [{locked_id, locked_cve}, {concurrent_id, concurrent_cve}] =
      Repo.all(
        from(advisory in "vulnerability_advisories",
          where: advisory.provider == ^@provider and advisory.feed_key == ^feed_key,
          order_by: advisory.id,
          select: {advisory.id, advisory.cve_id}
        ),
        prefix: @schema
      )

    assert {1, nil} =
             Repo.update_all(
               from(advisory in "vulnerability_advisories",
                 where: advisory.id == ^locked_id
               ),
               [set: [current: false]],
               prefix: @schema
             )

    Repo.delete_all(
      from(history in "advisory_package_assertion_history",
        where: history.provider == ^@provider and history.feed_key == ^feed_key
      ),
      prefix: @schema
    )

    parent = self()

    locker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT id FROM platform.vulnerability_advisories WHERE id = $1 FOR UPDATE",
            [locked_id]
          )

          send(parent, :reap_lock_held)

          receive do
            :release_reap_lock -> :ok
          after
            5_000 -> raise "reaper fixture lock was not released"
          end
        end)
      end)

    assert_receive :reap_lock_held, 5_000

    reaper =
      Task.async(fn ->
        Repo.transaction(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:reaper_backend, backend_pid})
          Loader.reap_old_generations(@provider, feed_key, generation + 2)
        end)
      end)

    assert_receive {:reaper_backend, backend_pid}, 5_000
    assert wait_for_backend_lock(backend_pid)

    # This demotion commits after the reaper statement has its snapshot. It is
    # not in the locked CTE set and therefore cannot be picked up by DELETE.
    assert {1, nil} =
             Repo.update_all(
               from(advisory in "vulnerability_advisories",
                 where: advisory.id == ^concurrent_id
               ),
               [set: [current: false]],
               prefix: @schema
             )

    send(locker.pid, :release_reap_lock)
    assert {:ok, :ok} = Task.await(locker, 5_000)
    assert {:ok, :ok} = Task.await(reaper, 5_000)

    assert [^locked_cve] = history_cves(feed_key)

    assert Repo.exists?(
             from(advisory in "vulnerability_advisories",
               where: advisory.id == ^concurrent_id and advisory.current == false
             ),
             prefix: @schema
           )

    assert Repo.exists?(
             from(assertion in "advisory_package_assertions",
               where: assertion.advisory_ref == ^concurrent_id
             ),
             prefix: @schema
           )

    assert :ok = Loader.reap_old_generations(@provider, feed_key, generation + 2)
    assert Enum.sort(history_cves(feed_key)) == Enum.sort([locked_cve, concurrent_cve])
  end

  @tag :tmp_dir
  test "Ubuntu projected worker loads validated records, applies tombstones, and rolls back a late failure",
       %{feed_key: feed_key, tmp_dir: tmp_dir} do
    projected = read_ubuntu_fixture("projected_record_v2.json")
    manifest = ubuntu_manifest()

    assert {:ok, paired} =
             Ubuntu.parse_record(projected,
               provider: @provider,
               feed_key: feed_key,
               source_digests: ubuntu_source_digests()
             )

    first_frames =
      ubuntu_record_frame(projected) <>
        ubuntu_terminal_frame(projected, manifest)

    {helper, helper_args_prefix} = ubuntu_helper!(tmp_dir, first_frames, "first")
    acquired = compact_ubuntu_acquired(tmp_dir, "first")

    assert {:ok, complete} =
             FeedWorker.load_ubuntu_snapshot(acquired,
               provider: @provider,
               feed_key: feed_key,
               helper: helper,
               helper_args_prefix: helper_args_prefix,
               runner: ubuntu_manifest_runner(manifest)
             )

    assert complete.source_objects_seen == 1
    assert complete.validation["osv"]["count"] == 1
    assert complete.validation["vex"]["count"] == 1
    assert complete.validation["projection"] == %{"complete" => true, "version" => 2}
    assert current_source_ids(feed_key) == ["UBUNTU-CVE-2099-424242"]

    assert Repo.exists?(
             from(assertion in "advisory_package_assertions",
               join: advisory in "vulnerability_advisories",
               on: advisory.id == assertion.advisory_ref,
               where:
                 advisory.provider == ^@provider and advisory.feed_key == ^feed_key and
                   advisory.source_object_id == "UBUNTU-CVE-2099-424242" and
                   assertion.source_kind == "ubuntu_openvex" and
                   assertion.disposition == "not_affected"
             ),
             prefix: @schema
           )

    tombstone = %{
      paired
      | advisory: %{paired.advisory | modified_at: ~U[2099-04-09 10:11:12Z]},
        coordinates: [],
        products: [],
        product_sets: [],
        assertions: []
    }

    assert {_tombstone_result, _generation} = load(feed_key, [tombstone])
    assert child_values(feed_key, "UBUNTU-CVE-2099-424242") == {[], []}

    generations_before = presence_generations(feed_key)
    current_before = current_source_ids(feed_key)
    changed = put_in(paired, [:advisory, :modified_at], ~U[2099-04-10 11:12:13Z])

    late_failure =
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {[changed], :fail}
          :fail -> raise "late Ubuntu helper failure"
        end,
        fn _ -> :ok end
      )

    assert_raise RuntimeError, ~r/late Ubuntu helper failure/, fn ->
      Loader.load_and_finalize(late_failure,
        provider: @provider,
        feed_key: feed_key,
        chunk_size: 1,
        completeness: complete_snapshot(1)
      )
    end

    assert presence_generations(feed_key) == generations_before
    assert current_source_ids(feed_key) == current_before
    assert child_values(feed_key, "UBUNTU-CVE-2099-424242") == {[], []}
  end

  defp compact_ubuntu_acquired(tmp_dir, suffix) do
    osv_path = Path.join(tmp_dir, "#{suffix}-osv.tar.xz")
    vex_path = Path.join(tmp_dir, "#{suffix}-vex.tar.xz")
    File.write!(osv_path, "o")
    File.write!(vex_path, "v")

    %{
      format: :ubuntu_tar_xz_pair,
      osv_path: osv_path,
      vex_path: vex_path,
      prepared_dir: Path.join(tmp_dir, "#{suffix}-prepared"),
      generation_provenance: String.duplicate("c", 64),
      acquired_at: ~U[2099-04-08 09:10:11Z],
      artifacts: %{
        osv: %{
          url: "https://feeds.example.invalid/osv",
          etag: "osv",
          sha256: @ubuntu_osv_digest,
          bytes: 1
        },
        vex: %{
          url: "https://feeds.example.invalid/vex",
          etag: "vex",
          sha256: @ubuntu_vex_digest,
          bytes: 1
        }
      }
    }
  end

  defp ubuntu_source_digests, do: %{osv: @ubuntu_osv_digest, vex: @ubuntu_vex_digest}

  defp ubuntu_manifest do
    base = %{
      version: 2,
      projection_version: 2,
      osv: ubuntu_inventory("osv", "osv.spool", @ubuntu_osv_digest),
      vex: ubuntu_inventory("vex", "vex.spool", @ubuntu_vex_digest),
      input_bytes: 2,
      work_bytes: 0,
      peak_work_bytes: 0,
      work_limit_bytes: 1_073_741_824
    }

    converge_ubuntu_manifest(base)
  end

  defp ubuntu_inventory(kind, spool, digest) do
    %{
      kind: kind,
      spool: spool,
      refs: [%{cve: "CVE-2099-424242"}],
      count: 1,
      members: 1,
      total: 1,
      archive_bytes: 1,
      archive_sha256: digest,
      spool_bytes: byte_size("fixture"),
      initial_runs: 1,
      merge_passes: 0
    }
  end

  defp converge_ubuntu_manifest(manifest) do
    encoded = Jason.encode!(manifest)
    work_bytes = manifest.input_bytes + manifest.osv.spool_bytes + manifest.vex.spool_bytes
    next = %{manifest | work_bytes: work_bytes + byte_size(encoded)}
    next = %{next | peak_work_bytes: next.work_bytes}

    if next == manifest, do: manifest, else: converge_ubuntu_manifest(next)
  end

  defp ubuntu_manifest_runner(manifest) do
    fn _helper, args, _opts ->
      dir = List.last(args)
      File.mkdir!(dir)
      File.write!(Path.join(dir, "osv.spool"), "fixture")
      File.write!(Path.join(dir, "vex.spool"), "fixture")
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest))
      {"", 0}
    end
  end

  defp ubuntu_record_frame(projected),
    do: projected |> Jason.encode!() |> then(&ubuntu_packet(<<1, &1::binary>>))

  defp ubuntu_terminal_frame(projected, manifest) do
    {:ok, _record, context, counters} =
      Ubuntu.validate_record(projected, source_digests: ubuntu_source_digests())

    terminal = %{
      "protocol_version" => 2,
      "cve_count" => 1,
      "record_count" => 1,
      "osv_document_count" => counters.osv_documents,
      "vex_document_count" => counters.vex_documents,
      "osv_count" => manifest.osv.count,
      "vex_count" => manifest.vex.count,
      "withdrawn_document_count" => counters.withdrawn_documents,
      "vex_tombstone_count" => counters.vex_tombstones,
      "osv_affected_entry_count" => counters.osv_affected_entries,
      "vex_statement_count" => counters.vex_statements,
      "logical_product_occurrence_count" => counters.logical_product_occurrences,
      "unique_product_count" => map_size(context.products),
      "unique_product_set_count" => map_size(context.product_sets),
      "assertion_count" => counters.assertions,
      "unscoped_product_count" => counters.unscoped_products,
      "repaired_source_purl_count" => counters.repaired_source_purls,
      "emitted_bytes" => 0,
      "emitted_frame_count" => 2,
      "max_frame_bytes" => 0,
      "osv_members" => manifest.osv.members,
      "vex_members" => manifest.vex.members,
      "osv_spool_bytes" => manifest.osv.spool_bytes,
      "vex_spool_bytes" => manifest.vex.spool_bytes,
      "peak_work_bytes" => manifest.peak_work_bytes
    }

    record_payload = <<1, Jason.encode!(projected)::binary>>

    terminal =
      converge_ubuntu_terminal(terminal, 4 + byte_size(record_payload), byte_size(record_payload))

    ubuntu_packet(<<2, Jason.encode!(terminal)::binary>>)
  end

  defp converge_ubuntu_terminal(terminal, prior_bytes, prior_max) do
    terminal_bytes = 1 + byte_size(Jason.encode!(terminal))

    next =
      terminal
      |> Map.put("emitted_bytes", prior_bytes + 4 + terminal_bytes)
      |> Map.put("max_frame_bytes", max(prior_max, terminal_bytes))

    if next == terminal,
      do: terminal,
      else: converge_ubuntu_terminal(next, prior_bytes, prior_max)
  end

  defp ubuntu_packet(payload), do: <<byte_size(payload)::32-big, payload::binary>>

  defp ubuntu_helper!(tmp_dir, output, suffix) do
    path = Path.join(tmp_dir, "ubuntu-helper-#{suffix}.exs")

    body =
      "#!/usr/bin/env elixir\n:io.setopts(:standard_io, encoding: :latin1)\n" <>
        "Base.decode64!(\"#{Base.encode64(output)}\") |> IO.binwrite()\n"

    File.write!(path, body)
    File.chmod!(path, 0o755)
    {path, []}
  end

  test "missing child keys are invalid and cannot masquerade as explicit withdrawal", %{
    feed_key: feed_key
  } do
    source_object_id = "ITEST-CVE-MISSING-KEY"
    initial = record(source_object_id, "2024-01-01T00:00:00Z")
    load(feed_key, [initial])
    original_children = child_values(feed_key, source_object_id)

    invalid =
      source_object_id
      |> record("2024-02-01T00:00:00Z", coordinates: [])
      |> Map.delete(:assertions)

    assert_raise ArgumentError, ~r/loader record contract/, fn ->
      Loader.load_and_finalize([invalid],
        provider: @provider,
        feed_key: feed_key,
        completeness: complete_snapshot(1)
      )
    end

    assert child_values(feed_key, source_object_id) == original_children
  end

  test "duplicate source ids cannot satisfy the claimed distinct snapshot count", %{
    feed_key: feed_key
  } do
    duplicate = record("ITEST-CVE-DUPLICATE", "2024-01-01T00:00:00Z")

    assert {:error, {:source_count_changed, details}} =
             Loader.load_and_finalize([duplicate, duplicate],
               provider: @provider,
               feed_key: feed_key,
               chunk_size: 1,
               completeness: complete_snapshot(2)
             )

    assert details[:expected] == 2
    assert details[:observed] == 1
    assert live_count(feed_key) == 0
  end

  test "conflicting duplicate assertion keys abort the whole snapshot", %{feed_key: feed_key} do
    source_object_id = "ITEST-CVE-ASSERTION-CONFLICT"
    initial = record(source_object_id, "2024-01-01T00:00:00Z")
    load(feed_key, [initial])
    original_children = child_values(feed_key, source_object_id)

    changed =
      record(source_object_id, "2024-02-01T00:00:00Z",
        assertions: [
          assertion("same-key", source_object_id, "package-a"),
          assertion("same-key", source_object_id, "package-b")
        ]
      )

    assert_raise ArgumentError, ~r/conflicting assertion_key/, fn ->
      Loader.load_and_finalize([changed],
        provider: @provider,
        feed_key: feed_key,
        completeness: complete_snapshot(1)
      )
    end

    assert child_values(feed_key, source_object_id) == original_children
  end

  test "a validated complete generation retires only current advisories absent from its presence",
       %{
         feed_key: feed_key
       } do
    [kept, withdrawn | _] = all_records()
    load(feed_key, [kept, withdrawn])

    # Make the withdrawn content generation old enough that the legacy
    # numeric-generation reaper would delete it during the next promotion.
    for index <- 1..3 do
      Loader.next_generation("unrelated-provider", "unrelated-feed-#{index}")
    end

    {result, generation} = load(feed_key, [kept])

    assert result.advisories_skipped == 1
    assert presence_exists?(feed_key, generation, kept.advisory.source_object_id)
    assert current_source_ids(feed_key) == [kept.advisory.source_object_id]
    assert advisory_id(feed_key, withdrawn.advisory.source_object_id)
  end

  test "empty, partial, corrupt, errored, and incomplete generations cannot demote", %{
    feed_key: feed_key
  } do
    [kept, protected | _] = all_records()
    load(feed_key, [kept, protected])

    invalid_overrides = [
      %{source_objects_seen: 0},
      %{complete_snapshot?: false},
      %{validation: %{"records" => %{"complete" => false, "count" => 1}}},
      %{parse_errors: 1},
      %{read_errors: 1},
      %{required_trees: ["records", "missing"]}
    ]

    for overrides <- invalid_overrides do
      records = if overrides[:source_objects_seen] == 0, do: [], else: [kept]

      {result, generation} =
        case records do
          [] -> {%{source_objects_seen: 0}, Loader.next_generation(@provider, feed_key)}
          _ -> load_generation(feed_key, records)
        end

      completeness = complete_snapshot(result.source_objects_seen, overrides)

      assert {:error, {:incomplete_snapshot, [_ | _]}} =
               Loader.finalize(@provider, feed_key, generation, completeness: completeness)

      assert current_source_ids(feed_key) ==
               Enum.sort([kept.advisory.source_object_id, protected.advisory.source_object_id])
    end
  end

  test "finalize/4 requires explicit validated completeness", %{feed_key: feed_key} do
    assert_raise KeyError, fn ->
      Loader.finalize(@provider, feed_key, 1, [])
    end
  end

  defp kev_record do
    %{
      advisory: %{
        source_object_id: "CVE-2026-KEV-0001",
        advisory_id: "CVE-2026-KEV-0001",
        cve_id: "CVE-2026-KEV-0001",
        title: "KEV test advisory",
        description: "KEV description",
        severity: "critical",
        modified_at: nil,
        kev: true,
        exploit_available: true,
        raw: %{"cveID" => "CVE-2026-KEV-0001"},
        metadata: %{"catalogVersion" => "2026.09.01"}
      },
      coordinates: [
        %{
          coordinate_type: "cpe",
          value: "cpe:2.3:a:example:kev:1.0:*:*:*:*:*:*:*",
          cpe_part: "a",
          cpe_vendor: "example",
          cpe_product: "kev",
          cpe_version: "1.0",
          metadata: %{"match_criteria_id" => "kev-coordinate"}
        }
      ],
      assertions: []
    }
  end

  defp duplicate_coordinate_kev_record(opts \\ []) do
    coordinates = [
      %{
        coordinate_type: "cpe",
        value: "cpe:2.3:a:example:kev:1.0:*:*:*:*:*:*:*",
        cpe_part: "a",
        cpe_vendor: "example",
        cpe_product: "zeta",
        cpe_version: "1.0",
        metadata: %{"match_criteria_id" => "alternate-coordinate"}
      },
      %{
        coordinate_type: "cpe",
        value: "cpe:2.3:a:example:kev:1.0:*:*:*:*:*:*:*",
        cpe_part: "a",
        cpe_vendor: "example",
        cpe_product: "alpha",
        cpe_version: "1.0",
        metadata: %{"match_criteria_id" => "canonical-coordinate"}
      }
    ]

    coordinates =
      if Keyword.get(opts, :reverse?, false), do: Enum.reverse(coordinates), else: coordinates

    %{
      advisory: %{
        source_object_id: "CVE-2026-KEV-DUPLICATE",
        advisory_id: "CVE-2026-KEV-DUPLICATE",
        cve_id: "CVE-2026-KEV-DUPLICATE",
        title: "KEV duplicate coordinate advisory",
        description: "KEV description",
        severity: "critical",
        modified_at: nil,
        kev: true,
        exploit_available: true,
        raw: %{"cveID" => "CVE-2026-KEV-DUPLICATE"},
        metadata: %{"catalogVersion" => "2026.09.01"}
      },
      coordinates: coordinates,
      assertions: []
    }
  end

  test "presence-only generations are never reused", %{feed_key: feed_key} do
    [record | _] = all_records()
    {_first, first_generation} = load(feed_key, [record])
    {_second, presence_only_generation} = load(feed_key, [record])

    assert presence_only_generation > first_generation
    assert Loader.next_generation(@provider, feed_key) > presence_only_generation
  end

  test "presence cleanup retains the last three actual feed generations across global gaps", %{
    feed_key: feed_key
  } do
    [record | _] = all_records()

    generations =
      Enum.map(1..4, fn index ->
        {_result, generation} = load(feed_key, [record])

        for gap <- 1..4 do
          Loader.next_generation("unrelated-provider", "gap-#{index}-#{gap}")
        end

        generation
      end)

    assert presence_generations(feed_key) == Enum.take(generations, -3)
  end
end
