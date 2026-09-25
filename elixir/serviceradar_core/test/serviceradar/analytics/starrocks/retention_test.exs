defmodule ServiceRadar.Analytics.StarRocks.RetentionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Retention

  @moduletag :db_free

  @env_vars ~w(
    SERVICERADAR_STARROCKS_RETENTION_DAYS_FLOWS
    SERVICERADAR_STARROCKS_RETENTION_DAYS_METRICS
    SERVICERADAR_STARROCKS_RETENTION_DAYS_LOGS
    SERVICERADAR_STARROCKS_RETENTION_DAYS_EVENTS
    SERVICERADAR_STARROCKS_RETENTION_DAYS_MTR
  )

  setup do
    original = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "each dataset keeps its own retention, defaulting to the shipped policy" do
    assert Env.config()[:retention_days] == [
             flows: 90,
             metrics: 90,
             logs: 365,
             events: 365,
             mtr: 30
           ]

    System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS_FLOWS", "30")
    System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS_LOGS", "730")

    # Raw NetFlow can be bounded without also shortening log history, which one
    # shared value could not express.
    assert Env.config()[:retention_days] == [
             flows: 30,
             metrics: 90,
             logs: 730,
             events: 365,
             mtr: 30
           ]

    for invalid <- ["", "0", "-5", "forever"] do
      System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS_FLOWS", invalid)
      assert Env.config()[:retention_days][:flows] == 90
    end
  end

  test "every partitioned telemetry table is retained at its dataset's depth" do
    statements = Retention.statements(retention_days: [flows: 30, logs: 730])

    assert length(statements) == length(Retention.tables())

    expected = %{
      "ocsf_network_activity" => "30",
      "logs" => "730",
      "timeseries_metrics" => "90",
      "events" => "365",
      "mtr_traces" => "30",
      "mtr_hops" => "30"
    }

    for {table, days} <- expected do
      assert Enum.any?(statements, fn sql ->
               sql =~ "ALTER TABLE `#{table}`" and
                 sql =~ ~s("partition_live_number" = "#{days}")
             end),
             "no retention statement for #{table} at #{days} days"
    end

    # Unqualified table names: the connection already selects the configured
    # database, so a non-default SERVICERADAR_STARROCKS_DATABASE still applies.
    refute Enum.any?(statements, &String.contains?(&1, "serviceradar."))
  end

  # A trace without its hops, or hops without their trace, is not an MTR
  # record, so the two tables share one setting.
  test "MTR traces and hops are retained together at the one MTR setting" do
    System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS_MTR", "14")
    assert Env.config()[:retention_days][:mtr] == 14

    days = Map.new(Retention.days_by_table(Env.config()))
    assert days["mtr_traces"] == 14
    assert days["mtr_hops"] == 14
    assert days["logs"] == 365
  end

  test "applying retention stops at the first failure and reports it" do
    executed = :counters.new(1, [])

    assert {:error, :connect_failed} =
             Retention.apply_retention(
               config: [retention_days: [flows: 90]],
               query: fn _sql ->
                 :counters.add(executed, 1, 1)
                 {:error, :connect_failed}
               end
             )

    assert :counters.get(executed, 1) == 1
  end

  test "a slow warehouse is retried with growing backoff rather than given up on" do
    parent = self()

    assert :ok =
             Retention.run(
               config: [retention_days: [flows: 90]],
               attempts: 4,
               sleep: fn delay -> send(parent, {:slept, delay}) end,
               query: fn _ -> {:error, :connect_failed} end
             )

    assert_received {:slept, 5_000}
    assert_received {:slept, 10_000}
    assert_received {:slept, 20_000}
    refute_received {:slept, _}
  end

  test "retention lands on an answer that arrives after the FE finishes starting" do
    attempt = :counters.new(1, [])
    applied = :counters.new(1, [])

    assert :ok =
             Retention.run(
               config: [retention_days: [flows: 45]],
               sleep: fn _ -> :ok end,
               query: fn sql ->
                 :counters.add(attempt, 1, 1)

                 if :counters.get(attempt, 1) <= 20 do
                   {:error, :connect_failed}
                 else
                   assert sql =~ "partition_live_number"
                   :counters.add(applied, 1, 1)
                   {:ok, %{}}
                 end
               end
             )

    assert :counters.get(applied, 1) == length(Retention.tables())
  end

  test "retention is applied once the warehouse answers" do
    applied = :counters.new(1, [])

    assert :ok =
             Retention.run(
               config: [retention_days: [flows: 45]],
               attempts: 3,
               sleep: fn _ -> flunk("retried a successful apply") end,
               query: fn sql ->
                 :counters.add(applied, 1, 1)
                 {:ok, %{}}
               end
             )

    assert :counters.get(applied, 1) == length(Retention.tables())
  end
end
