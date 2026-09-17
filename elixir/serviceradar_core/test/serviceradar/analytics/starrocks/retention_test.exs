defmodule ServiceRadar.Analytics.StarRocks.RetentionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Retention

  @moduletag :db_free

  setup do
    original = System.get_env("SERVICERADAR_STARROCKS_RETENTION_DAYS")

    on_exit(fn ->
      case original do
        nil -> System.delete_env("SERVICERADAR_STARROCKS_RETENTION_DAYS")
        value -> System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS", value)
      end
    end)

    :ok
  end

  test "retention defaults to 90 daily partitions and follows the operator value" do
    System.delete_env("SERVICERADAR_STARROCKS_RETENTION_DAYS")
    assert Env.config()[:retention_days] == 90

    System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS", "30")
    assert Env.config()[:retention_days] == 30

    for invalid <- ["", "0", "-5", "forever"] do
      System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS", invalid)
      assert Env.config()[:retention_days] == 90
    end
  end

  test "every partitioned telemetry table is retained at the configured depth" do
    statements = Retention.statements(retention_days: 30)

    assert length(statements) == length(Retention.tables())

    for table <- Retention.tables() do
      assert Enum.any?(statements, fn sql ->
               sql =~ "ALTER TABLE `#{table}`" and sql =~ ~s("partition_live_number" = "30")
             end)
    end

    # Unqualified table names: the connection already selects the configured
    # database, so a non-default SERVICERADAR_STARROCKS_DATABASE still applies.
    refute Enum.any?(statements, &String.contains?(&1, "serviceradar."))
  end

  test "applying retention stops at the first failure and reports it" do
    executed = :counters.new(1, [])

    assert {:error, :connect_failed} =
             Retention.apply_retention(
               config: [retention_days: 90],
               query: fn _sql ->
                 :counters.add(executed, 1, 1)
                 {:error, :connect_failed}
               end
             )

    assert :counters.get(executed, 1) == 1
  end

  test "a warehouse that never answers does not crash the boot task" do
    parent = self()

    assert :ok =
             Retention.run(
               config: [retention_days: 90],
               attempts: 3,
               sleep: fn _ -> send(parent, :slept) end,
               query: fn _ -> {:error, :connect_failed} end
             )

    assert_received :slept
    assert_received :slept
    refute_received :slept
  end

  test "retention is applied once the warehouse answers" do
    applied = :counters.new(1, [])

    assert :ok =
             Retention.run(
               config: [retention_days: 45],
               attempts: 3,
               sleep: fn _ -> flunk("retried a successful apply") end,
               query: fn sql ->
                 assert sql =~ ~s("partition_live_number" = "45")
                 :counters.add(applied, 1, 1)
                 {:ok, %{}}
               end
             )

    assert :counters.get(applied, 1) == length(Retention.tables())
  end
end
