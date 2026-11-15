defmodule ServiceRadar.Repo.BaselineInstallRepairWorkerDbTest do
  @moduledoc """
  `BaselineInstallRepairWorker` against the real hypertables and seed tables.

  The lane database is a migration replay, so each case first puts it in the state an older,
  data-less baseline left: compression off, policies missing, seed rows absent. All of it runs
  inside the DataCase transaction and rolls back. Serial: the Timescale DDL touches shared
  hypertables.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.BaselineInstallRepairWorker

  @moduletag :integration

  test "a baseline-created database gets the missing state and keeps what it has" do
    mark_baseline_install()
    leave_like_old_baseline()

    # An operator chose a longer MTR history; the repair must not undo it.
    Repo.query!(
      "SELECT a.job_id FROM timescaledb_information.jobs j, " <>
        "LATERAL alter_job(j.job_id, config => jsonb_set(j.config, '{drop_after}', '\"45 days\"')) a " <>
        "WHERE proc_name = 'policy_retention' AND hypertable_name = 'mtr_traces'"
    )

    assert :ok = perform()

    assert compression("mtr_hops") == {true, "addr", ~s("time" DESC,id)}
    assert policy("policy_compression", "mtr_hops") == "7 days"
    assert policy("policy_retention", "bmp_routing_events") == "3 days"
    assert policy("policy_retention", "mtr_traces") == "45 days"
    assert count("availability_settings") == 1
    assert count("interface_classification_rules") == 3
    assert count("plugin_repositories") == 1

    # Owned by DataRetentionWorker.
    assert compression("timeseries_metrics") == {false, nil, nil}

    # A second run finds nothing to do and duplicates nothing.
    assert :ok = perform()
    assert count("interface_classification_rules") == 3
    assert count("availability_settings") == 1
  end

  test "a replayed database is left alone" do
    # The lane database is a migration replay, which never records a baseline.
    assert Repo.query!("SELECT to_regclass('platform.serviceradar_schema_baselines')").rows ==
             [[nil]]

    leave_like_old_baseline()

    assert :ok = perform()

    assert compression("mtr_hops") == {false, nil, nil}
    assert policy("policy_retention", "bmp_routing_events") == nil
    assert count("availability_settings") == 0
  end

  defp perform, do: BaselineInstallRepairWorker.perform(%Oban.Job{args: %{}})

  defp mark_baseline_install do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS platform.serviceradar_schema_baselines (
      version integer NOT NULL PRIMARY KEY,
      included_through bigint NOT NULL,
      schema_sha256 text NOT NULL,
      applied_at timestamp(0) without time zone NOT NULL DEFAULT NOW()
    )
    """)
  end

  defp leave_like_old_baseline do
    for table <- ~w(mtr_hops timeseries_metrics) do
      Repo.query!("SELECT remove_compression_policy('platform.#{table}', if_exists => true)")
      Repo.query!("ALTER TABLE platform.#{table} SET (timescaledb.compress = false)")
    end

    Repo.query!(
      "SELECT remove_retention_policy('platform.bmp_routing_events', if_exists => true)"
    )

    Repo.query!("DELETE FROM platform.availability_settings")
    Repo.query!("DELETE FROM platform.interface_classification_rules")

    assert compression("mtr_hops") == {false, nil, nil}
    assert policy("policy_retention", "bmp_routing_events") == nil
  end

  defp compression(table) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT h.compression_enabled,
               CASE WHEN h.compression_enabled THEN s.segmentby END,
               CASE WHEN h.compression_enabled THEN s.orderby END
        FROM timescaledb_information.hypertables h
        LEFT JOIN timescaledb_information.hypertable_compression_settings s
          ON s.hypertable = format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass
        WHERE h.hypertable_schema = 'platform' AND h.hypertable_name = $1
        """,
        [table]
      )

    List.to_tuple(row)
  end

  defp policy(proc_name, table) do
    case Repo.query!(
           """
           SELECT coalesce(config->>'compress_after', config->>'drop_after')
           FROM timescaledb_information.jobs
           WHERE proc_name = $1 AND hypertable_schema = 'platform' AND hypertable_name = $2
           """,
           [proc_name, table]
         ) do
      %{rows: [[value]]} -> value
      %{rows: []} -> nil
    end
  end

  defp count(table) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM platform.#{table}")
    count
  end
end
