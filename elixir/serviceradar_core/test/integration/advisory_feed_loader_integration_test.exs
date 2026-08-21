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

  alias ServiceRadar.Inventory.AdvisoryFeeds.Loader
  alias ServiceRadar.Repo

  @moduletag :integration

  @provider "test-provider"
  @schema "platform"

  setup do
    feed_key = "loader-itest-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup(feed_key) end)
    {:ok, feed_key: feed_key}
  end

  defp cleanup(feed_key) do
    Repo.delete_all(
      from(a in "vulnerability_advisories",
        where: a.provider == ^@provider and a.feed_key == ^feed_key
      ),
      prefix: @schema
    )
  rescue
    _ -> :ok
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
end
