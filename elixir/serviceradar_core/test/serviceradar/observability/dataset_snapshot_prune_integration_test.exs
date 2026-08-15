defmodule ServiceRadar.Observability.DatasetSnapshotPruneIntegrationTest do
  @moduledoc """
  DB-backed coverage for inactive provider-snapshot pruning.

  Run against a migrated scratch database with `--include integration`.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.DatasetSnapshotPrune
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag timeout: 120_000

  test "keeps the active snapshot and the newest inactive copy, batch-deletes the rest" do
    Repo.query!("DELETE FROM platform.netflow_provider_cidrs", [])
    Repo.query!("DELETE FROM platform.netflow_provider_dataset_snapshots", [])

    active_id = insert_snapshot(true, ~U[2026-08-14 12:22:44Z], 2)
    keep_id = insert_snapshot(false, ~U[2026-08-13 08:21:58Z], 2)
    doomed_id = insert_snapshot(false, ~U[2026-08-07 12:16:37Z], 2)

    insert_cidr(active_id, "203.0.113.0/24")
    insert_cidr(active_id, "203.0.113.128/25")
    insert_cidr(keep_id, "198.51.100.0/24")
    insert_cidr(keep_id, "198.51.100.128/25")
    insert_cidr(doomed_id, "192.0.2.0/24")
    insert_cidr(doomed_id, "192.0.2.128/25")

    assert {:ok,
            %{
              deleted_snapshots: 1,
              deleted_entries: 2,
              remaining_doomed: 0
            }} =
             DatasetSnapshotPrune.run(
               "netflow_provider_dataset_snapshots",
               "netflow_provider_cidrs",
               retention_days: 2,
               keep_last: 1,
               entry_batch_size: 1
             )

    leftover =
      Repo.query!(
        "SELECT id FROM platform.netflow_provider_dataset_snapshots ORDER BY fetched_at DESC"
      )

    leftover_ids = Enum.map(leftover.rows, fn [id] -> id end)
    assert active_id in leftover_ids
    assert keep_id in leftover_ids
    refute doomed_id in leftover_ids

    assert [[2]] =
             Repo.query!(
               "SELECT COUNT(*) FROM platform.netflow_provider_cidrs WHERE snapshot_id = $1",
               [active_id]
             ).rows

    assert [[2]] =
             Repo.query!(
               "SELECT COUNT(*) FROM platform.netflow_provider_cidrs WHERE snapshot_id = $1",
               [keep_id]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT COUNT(*) FROM platform.netflow_provider_cidrs WHERE snapshot_id = $1",
               [doomed_id]
             ).rows
  end

  defp insert_snapshot(active?, fetched_at, record_count) do
    {:ok, %{rows: [[id]]}} =
      Repo.query(
        """
        INSERT INTO platform.netflow_provider_dataset_snapshots
          (id, source_url, fetched_at, promoted_at, is_active, record_count)
        VALUES
          (gen_random_uuid(), 'https://fixture.invalid/providers.json',
           $1, $1, $2, $3)
        RETURNING id
        """,
        [fetched_at, active?, record_count]
      )

    id
  end

  defp insert_cidr(snapshot_id, cidr) do
    Repo.query!(
      """
      INSERT INTO platform.netflow_provider_cidrs
        (snapshot_id, cidr, provider, service, region, ip_version)
      VALUES ($1, $2::cidr, 'fixture-cloud', 'edge', 'test', 'ipv4')
      """,
      [snapshot_id, cidr]
    )
  end
end
