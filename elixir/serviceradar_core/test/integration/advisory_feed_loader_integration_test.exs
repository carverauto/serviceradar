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

  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias ServiceRadar.Inventory.AdvisoryFeeds.Loader
  alias ServiceRadar.Repo

  @moduletag :integration

  @provider "test-provider"
  @schema "platform"

  setup do
    feed_key = "loader-itest-#{System.unique_integer([:positive])}"
    {:ok, feed_key: feed_key}
  end

  defp record(id, modified_at) do
    %{
      advisory: %{
        source_object_id: id,
        advisory_id: id,
        cve_id: id,
        title: "title #{id}",
        description: "desc",
        severity: "high",
        modified_at: modified_at,
        raw: %{"id" => id}
      },
      coordinates: [
        %{
          coordinate_type: "cpe",
          value: "cpe:2.3:a:vendor:product:1.0:*:*:*:*:*:*:*",
          metadata: %{}
        }
      ]
    }
  end

  # NVD emits no UTC offset, so this is the shape the real parser sees.
  @records [
    {"ITEST-CVE-0001", "2024-01-15T12:34:56.123"},
    {"ITEST-CVE-0002", "2024-02-20T01:02:03.000"},
    {"ITEST-CVE-0003", "2024-03-25T23:59:59.999"}
  ]

  # Mirrors FeedWorker.load_and_finalize/3 exactly: the demote decision is derived
  # from the load result via Loader.full_sweep?/1, never hardcoded. An earlier
  # version of this helper passed `demote_missing: true` unconditionally and
  # demoted the entire corpus on the second (fully-skipped) run — which is the
  # precise failure the gate exists to prevent.
  defp load(feed_key, records, opts \\ []) do
    generation = Loader.next_generation(@provider, feed_key)

    result =
      Loader.load_stream(records,
        provider: @provider,
        feed_key: feed_key,
        generation: generation
      )

    demote = Keyword.get_lazy(opts, :demote_missing, fn -> Loader.full_sweep?(result) end)
    Loader.finalize(@provider, feed_key, generation, demote_missing: demote)

    {result, generation}
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

  test "a second identical run skips every advisory and writes nothing", %{feed_key: feed_key} do
    {first, _gen} = load(feed_key, all_records())

    assert first.advisories_upserted == 3
    assert first.advisories_skipped == 0
    assert live_count(feed_key) == 3

    before = updated_ats(feed_key)

    {second, _gen} = load(feed_key, all_records())

    # THE regression assertion. Before the fix this was skipped: 0, upserted: 3.
    assert second.advisories_skipped == 3,
           "skip guard is inert: the whole corpus was rewritten on an unchanged run"

    assert second.advisories_upserted == 0
    assert second.coordinates_upserted == 0

    # Nothing was written, so no row's updated_at moved.
    assert updated_ats(feed_key) == before
    assert live_count(feed_key) == 3
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

    assert [{"zeta", %{"match_criteria_id" => "alternate-coordinate"}}] ==
             stored_coordinates(feed_key)

    {second, _gen} = load(feed_key, [duplicate_coordinate_kev_record(reverse?: true)])
    assert second.advisories_upserted == 0
    assert second.advisories_skipped == 1

    assert [{"zeta", %{"match_criteria_id" => "alternate-coordinate"}}] ==
             stored_coordinates(feed_key)
  end

  # The destructive failure mode this guards: skipped rows keep an older
  # generation while staying live. Demoting them would hide the corpus from the
  # matcher, and reap_old_generations/3 cascade-deletes demoted rows and their
  # coordinates.
  test "a skipping run must not demote or reap the rows it skipped", %{feed_key: feed_key} do
    load(feed_key, all_records())

    {second, _gen} = load(feed_key, all_records(), demote_missing: false)

    assert second.advisories_skipped == 3
    assert live_count(feed_key) == 3, "skipped advisories were demoted out of the matcher"

    coords =
      Repo.aggregate(
        from(c in "advisory_coordinates",
          where: c.provider == ^@provider and c.feed_key == ^feed_key
        ),
        :count,
        prefix: @schema
      )

    assert coords == 3, "coordinates of skipped advisories were cascade-deleted"
  end

  test "full_sweep?/1 refuses to authorise a demote on a skipping run", %{feed_key: feed_key} do
    {first, _gen} = load(feed_key, all_records())
    assert Loader.full_sweep?(first), "a first full load is a sweep"

    {second, _gen} = load(feed_key, all_records())
    refute Loader.full_sweep?(second), "a run that skipped rows must never authorise a demote"
  end

  # Demonstrates WHY the gate exists: forcing demote_missing on a skipping run
  # empties the live corpus. If this ever stops being destructive the gate can be
  # simplified — until then it is load-bearing.
  test "forcing demote_missing on a skipping run would wipe the corpus", %{feed_key: feed_key} do
    load(feed_key, all_records())
    assert live_count(feed_key) == 3

    {result, _gen} = load(feed_key, all_records(), demote_missing: true)

    assert result.advisories_skipped == 3
    assert live_count(feed_key) == 0
  end

  test "finalize/4 requires an explicit demote_missing decision", %{feed_key: feed_key} do
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
      ]
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
      coordinates: coordinates
    }
  end
end
