defmodule ServiceRadar.Inventory.Identity.RestoreMergedFirstSeenMigrationDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.RestoreMergedDeviceFirstSeen, as: Migration

  @moduletag :integration
  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260907090000_restore_merged_device_first_seen.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  Code.require_file(@migration_path)

  setup do
    Repo.query!("""
    CREATE TEMPORARY TABLE ocsf_devices (
      uid text PRIMARY KEY,
      first_seen_time timestamp,
      modified_time timestamp
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    CREATE TEMPORARY TABLE merge_audit (
      event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      from_device_id text,
      to_device_id text,
      reason text,
      details jsonb DEFAULT '{}'
    ) ON COMMIT DROP
    """)

    :ok
  end

  test "repairs the full chain through undated rows and is idempotent" do
    seed_devices([{"a", 2001}, {"b", nil}, {"c", 2003}, {"d", nil}])
    seed_merges([{"a", "b"}, {"b", "c"}, {"c", "d"}])

    assert %{num_rows: 3} = Repo.query!(Migration.repair_sql("pg_temp"))
    assert dates() == [["a", 2001], ["b", 2001], ["c", 2001], ["d", 2001]]
    assert %{num_rows: 0} = Repo.query!(Migration.repair_sql("pg_temp"))
  end

  test "neither direction of a reversed merge contributes a date" do
    seed_devices([{"a", 2003}, {"b", 2001}, {"c", 2001}, {"d", 2003}])
    seed_merges([{"a", "b"}, {"c", "d"}])

    Repo.query!("""
    INSERT INTO pg_temp.merge_audit (from_device_id, to_device_id, reason, details)
    SELECT to_device_id, from_device_id, 'unmerge',
           jsonb_build_object('original_merge_event_id', event_id)
    FROM pg_temp.merge_audit
    """)

    assert %{num_rows: 0} = Repo.query!(Migration.repair_sql("pg_temp"))
    assert dates() == [["a", 2003], ["b", 2001], ["c", 2001], ["d", 2003]]

    seed_merges([{"c", "d"}])
    assert %{num_rows: 1} = Repo.query!(Migration.repair_sql("pg_temp"))
    assert dates() == [["a", 2003], ["b", 2001], ["c", 2001], ["d", 2001]]
  end

  test "cycles terminate and propagate the earliest date" do
    seed_devices([{"a", 2001}, {"b", 2002}, {"c", 2003}])
    seed_merges([{"a", "b"}, {"b", "a"}, {"b", "c"}, {"c", "c"}])
    Repo.query!("SET LOCAL statement_timeout = '5s'")

    assert %{num_rows: 2} = Repo.query!(Migration.repair_sql("pg_temp"))
    assert dates() == [["a", 2001], ["b", 2001], ["c", 2001]]
    assert %{num_rows: 0} = Repo.query!(Migration.repair_sql("pg_temp"))
  end

  test "undated and newer sources never blank or raise a survivor date" do
    seed_devices([{"a", nil}, {"b", 2001}, {"c", 2003}, {"d", nil}])
    seed_merges([{"a", "b"}, {"c", "b"}, {"a", "d"}])

    assert %{num_rows: 0} = Repo.query!(Migration.repair_sql("pg_temp"))
    assert dates() == [["a", nil], ["b", 2001], ["c", 2003], ["d", nil]]
  end

  defp seed_devices(devices) do
    Enum.each(devices, fn {uid, year} ->
      Repo.query!(
        "INSERT INTO pg_temp.ocsf_devices (uid, first_seen_time) VALUES ($1, make_date($2, 1, 1))",
        [uid, year]
      )
    end)
  end

  defp seed_merges(edges) do
    Enum.each(edges, fn {source, target} ->
      Repo.query!(
        "INSERT INTO pg_temp.merge_audit (from_device_id, to_device_id, reason) VALUES ($1, $2, 'manual')",
        [source, target]
      )
    end)
  end

  defp dates do
    %{rows: rows} =
      Repo.query!(
        "SELECT uid, EXTRACT(YEAR FROM first_seen_time)::integer FROM pg_temp.ocsf_devices ORDER BY uid"
      )

    rows
  end
end
