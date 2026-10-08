defmodule ServiceRadar.Analytics.StarRocks.RetentionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Retention
  alias ServiceRadar.Analytics.StarRocks.RetentionSettings

  @moduletag :db_free

  @env_vars ~w(
    SERVICERADAR_STARROCKS_RETENTION_DAYS_FLOWS
    SERVICERADAR_STARROCKS_RETENTION_DAYS_METRICS
    SERVICERADAR_STARROCKS_RETENTION_DAYS_LOGS
    SERVICERADAR_STARROCKS_RETENTION_DAYS_EVENTS
    SERVICERADAR_STARROCKS_RETENTION_DAYS_MTR
    SERVICERADAR_STARROCKS_RETENTION_DAYS_OTEL
    SERVICERADAR_STARROCKS_RETENTION_DAYS_TRACES
    SERVICERADAR_STARROCKS_RETENTION_DAYS_BMP
    SERVICERADAR_STARROCKS_RETENTION_DAYS_ATTRIBUTION
  )

  # The settings rows as CNPG would hold them, keyed by dataset name. Stands in
  # for `Retention.Store` so the reconcile decisions run without a database.
  defmodule FakeStore do
    @moduledoc false
    use Agent

    def start_link(rows), do: Agent.start_link(fn -> rows end, name: __MODULE__)
    def rows, do: Agent.get(__MODULE__, & &1)
    def row(dataset), do: Map.fetch!(rows(), dataset)

    def put(dataset, attrs),
      do: Agent.update(__MODULE__, &Map.update!(&1, dataset, fn r -> Map.merge(r, attrs) end))

    def list, do: {:ok, Map.values(rows())}

    def seed(dataset, days) do
      row = %{
        dataset: dataset,
        days: days,
        seed_days: days,
        last_applied_days: nil,
        last_applied_status: "pending",
        last_applied_error: nil
      }

      Agent.update(__MODULE__, &Map.put(&1, dataset, row))
      {:ok, row}
    end

    def record_seed(row, attrs), do: update(row, attrs)
    def record_outcome(row, attrs), do: update(row, attrs)

    defp update(row, attrs) do
      put(row.dataset, attrs)
      {:ok, row(row.dataset)}
    end
  end

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

  defp applied_rows(overrides \\ %{}) do
    Map.new(Retention.datasets(), fn dataset ->
      days = Map.get(overrides, dataset, Retention.default_days(dataset))
      name = Atom.to_string(dataset)

      {name,
       %{
         dataset: name,
         days: days,
         seed_days: Retention.default_days(dataset),
         last_applied_days: days,
         last_applied_status: "applied",
         last_applied_error: nil
       }}
    end)
  end

  defp recording_query(result \\ {:ok, %{}}) do
    parent = self()

    fn sql ->
      send(parent, {:sql, sql})
      if is_function(result, 0), do: result.(), else: result
    end
  end

  # The ALTERs the applier issued, in order. The `SHOW CREATE TABLE` reads that
  # precede them are not changes to the warehouse.
  defp sent_sql do
    receive do
      {:sql, "ALTER" <> _ = sql} -> [sql | sent_sql()]
      {:sql, _read} -> sent_sql()
    after
      0 -> []
    end
  end

  # A warehouse whose tables currently keep `live` partitions (by table name),
  # answering ALTERs with `alter_result`.
  defp warehouse_query(live, alter_result) do
    parent = self()

    fn sql ->
      send(parent, {:sql, sql})

      case Regex.run(~r/^SHOW CREATE TABLE `([^`]+)`$/, sql) do
        [_, table] ->
          ddl =
            case Map.fetch(live, table) do
              {:ok, n} ->
                ~s|CREATE TABLE `#{table}` (...) PROPERTIES ("partition_live_number" = "#{n}")|

              :error ->
                "CREATE TABLE `#{table}` (...)"
            end

          {:ok, %{rows: [[table, ddl]]}}

        nil ->
          alter_result
      end
    end
  end

  describe "seed defaults" do
    test "each dataset keeps its own seed, defaulting to the shipped policy" do
      assert Env.config()[:retention_days] == [
               flows: 365,
               metrics: 365,
               logs: 365,
               events: 365,
               mtr: 365,
               otel: 365,
               traces: 365,
               bmp: 365,
               attribution: 30
             ]

      System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS_FLOWS", "30")
      System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS_ATTRIBUTION", "1")

      assert Env.config()[:retention_days][:flows] == 30
      assert Env.config()[:retention_days][:attribution] == 1
      assert Env.config()[:retention_days][:logs] == 365

      for invalid <- ["", "0", "-5", "forever"] do
        System.put_env("SERVICERADAR_STARROCKS_RETENTION_DAYS_FLOWS", invalid)
        assert Env.config()[:retention_days][:flows] == 365
      end
    end

    test "a dataset with no stored row is seeded from the environment and applied" do
      start_supervised!({FakeStore, %{}})
      seeds = Keyword.put(Env.default_retention_days(), :logs, 180)

      assert :ok =
               Retention.reconcile(
                 store: FakeStore,
                 seeds: seeds,
                 query: recording_query(),
                 force: true
               )

      assert %{days: 180, seed_days: 180, last_applied_status: "applied", last_applied_days: 180} =
               FakeStore.row("logs")

      assert %{days: 365, last_applied_status: "applied"} = FakeStore.row("metrics")
      assert %{days: 30, seed_days: 30} = FakeStore.row("attribution")

      sql = sent_sql()
      assert ~s|ALTER TABLE `logs` SET ("partition_live_number" = "180")| in sql
      assert length(sql) == length(Retention.tables())
    end

    test "a stored value wins over a changed seed, which is only recorded" do
      start_supervised!({FakeStore, applied_rows(%{logs: 90})})
      seeds = Keyword.put(Env.default_retention_days(), :logs, 180)

      assert :ok = Retention.reconcile(store: FakeStore, seeds: seeds, query: recording_query())

      assert %{days: 90, seed_days: 180, last_applied_days: 90} = FakeStore.row("logs")
      assert sent_sql() == []
    end
  end

  describe "applying a change" do
    test "a saved change issues the ALTER for that dataset only and records it applied" do
      start_supervised!({FakeStore, applied_rows()})
      FakeStore.put("events", %{days: 90, last_applied_status: "pending"})

      assert :ok =
               Retention.reconcile(
                 store: FakeStore,
                 seeds: Env.default_retention_days(),
                 query: recording_query()
               )

      assert sent_sql() == [~s|ALTER TABLE `events` SET ("partition_live_number" = "90")|]

      assert %{
               last_applied_status: "applied",
               last_applied_days: 90,
               last_applied_at: %DateTime{}
             } =
               FakeStore.row("events")
    end

    test "an unanswering Frontend leaves the dataset pending at its last applied value" do
      start_supervised!({FakeStore, applied_rows()})
      FakeStore.put("events", %{days: 90, last_applied_status: "pending"})

      assert :retry =
               Retention.reconcile(
                 store: FakeStore,
                 seeds: Env.default_retention_days(),
                 query: recording_query({:error, :connect_failed})
               )

      assert %{last_applied_status: "pending", last_applied_days: 365, last_applied_error: error} =
               FakeStore.row("events")

      assert error =~ "did not answer"
    end

    test "a warehouse that refuses the statement records the dataset failed with its message" do
      start_supervised!({FakeStore, applied_rows()})
      FakeStore.put("mtr", %{days: 30, last_applied_status: "pending"})

      assert :retry =
               Retention.reconcile(
                 store: FakeStore,
                 seeds: Env.default_retention_days(),
                 query:
                   recording_query({:error, {:starrocks_mysql, "Unknown table 'mtr_traces'"}})
               )

      assert %{last_applied_status: "failed", last_applied_error: "Unknown table 'mtr_traces'"} =
               FakeStore.row("mtr")
    end

    test "a table already keeping the wanted partitions is not altered again" do
      start_supervised!({FakeStore, applied_rows()})
      FakeStore.put("flows", %{last_applied_status: "pending"})

      assert :ok =
               Retention.reconcile(
                 store: FakeStore,
                 seeds: Env.default_retention_days(),
                 query: warehouse_query(%{"ocsf_network_activity" => 365}, {:error, :unexpected})
               )

      assert sent_sql() == []
      assert %{last_applied_status: "applied", last_applied_days: 365} = FakeStore.row("flows")
    end

    test "a schema change running on the table leaves the dataset pending, not failed" do
      start_supervised!({FakeStore, applied_rows()})
      FakeStore.put("flows", %{days: 90, last_applied_status: "pending"})

      busy =
        {:error,
         {:starrocks_mysql,
          "(1064) A schema change operation is in progress on the table ocsf_network_activity. " <>
            "Please wait until the current operation completes."}}

      assert :retry =
               Retention.reconcile(
                 store: FakeStore,
                 seeds: Env.default_retention_days(),
                 query: warehouse_query(%{"ocsf_network_activity" => 365}, busy)
               )

      assert sent_sql() == [
               ~s|ALTER TABLE `ocsf_network_activity` SET ("partition_live_number" = "90")|
             ]

      assert %{last_applied_status: "pending", last_applied_days: 365, last_applied_error: error} =
               FakeStore.row("flows")

      assert error =~ "schema change is still running on ocsf_network_activity"
    end

    test "reconciling from pending to applied logs at info and emits no warning" do
      start_supervised!({FakeStore, applied_rows()})
      FakeStore.put("flows", %{days: 90, last_applied_status: "pending", last_applied_days: 365})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Retention.reconcile(
                     store: FakeStore,
                     seeds: Env.default_retention_days(),
                     query: warehouse_query(%{"ocsf_network_activity" => 365}, {:ok, %{}})
                   )
        end)

      assert log =~ "StarRocks retention for flows applied: 90 days on ocsf_network_activity"
      refute log =~ "not applied"
      refute log =~ "[warning]"
    end

    test "applier_health reports whether a retention applier GenServer is running" do
      refute Retention.applier_health().running?

      start_supervised!(
        {Retention,
         name: Retention,
         subscribe: false,
         store: FakeStore,
         initial_delay_ms: 60_000,
         seeds: Env.default_retention_days(),
         query: warehouse_query(%{}, {:ok, %{}})}
      )

      health = Retention.applier_health()
      assert health.running?
      assert health.node == node()
    end

    test "the applier retries an unanswering warehouse and applies a broadcast change without a restart" do
      start_supervised!({FakeStore, applied_rows()})
      attempts = :counters.new(1, [])

      query =
        recording_query(fn ->
          :counters.add(attempts, 1, 1)
          if :counters.get(attempts, 1) <= 3, do: {:error, :connect_failed}, else: {:ok, %{}}
        end)

      opts = [
        name: :retention_under_test,
        store: FakeStore,
        seeds: Env.default_retention_days(),
        query: query,
        subscribe: false,
        initial_delay_ms: 5,
        interval_ms: 60_000
      ]

      pid =
        start_supervised!(%{id: :retention_under_test, start: {Retention, :start_link, [opts]}})

      # The start-up pass applies every dataset; the first three statements fail,
      # so the rows only all read applied again after a backed-off retry.
      wait_until(fn ->
        :counters.get(attempts, 1) > 3 and
          Enum.all?(Map.values(FakeStore.rows()), &applied_or_tableless?/1)
      end)

      _ = sent_sql()

      FakeStore.put("logs", %{days: 45, last_applied_status: "pending"})
      send(pid, {:warehouse_retention_changed, "logs"})

      assert_receive {:sql, ~s|ALTER TABLE `logs` SET ("partition_live_number" = "45")|}, 1_000
      wait_until(fn -> FakeStore.row("logs").last_applied_days == 45 end)
    end
  end

  describe "floors" do
    test "a value below the dataset's floor is rejected before anything is stored" do
      assert {:error, "must be at least 1 day"} =
               RetentionSettings.save("attribution", 0, actor: nil)

      assert {:error, "must be at least 1 day"} = RetentionSettings.save("logs", -3, actor: nil)
      assert {:error, "unknown dataset" <> _} = RetentionSettings.save("nope", 30, actor: nil)
    end

    test "process attribution never keeps fewer than two daily partitions" do
      assert Retention.partitions(:attribution, 1) == 2
      assert Retention.partitions(:attribution, 10) == 10
      assert Retention.partitions(:logs, 1) == 1
    end

    test "values far above the default warn" do
      refute Retention.storage_warning?(:logs, 730)
      assert Retention.storage_warning?(:logs, 731)
      assert Retention.storage_warning?(:attribution, 61)
    end
  end

  describe "statements" do
    test "every partitioned telemetry table is retained at its dataset's depth" do
      statements = Retention.statements(retention_days: [flows: 30, logs: 730])

      assert length(statements) == length(Retention.tables())

      expected = %{
        "ocsf_network_activity" => "30",
        "logs" => "730",
        "timeseries_metrics" => "365",
        "events" => "365",
        "mtr_traces" => "365",
        "mtr_hops" => "365",
        "otel_metrics" => "365",
        "otel_metric_points" => "365",
        "otel_traces" => "365",
        "bmp_routing_events" => "365",
        "flow_process_attribution_observations" => "30"
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
    # record; OTel samples and points are one signal. Each pair shares a setting.
    test "multi-table datasets are retained together at their one setting" do
      days = Map.new(Retention.days_by_table(retention_days: [mtr: 14, otel: 90]))

      assert days["mtr_traces"] == 14
      assert days["mtr_hops"] == 14
      assert days["otel_metrics"] == 90
      assert days["otel_metric_points"] == 90
      assert days["logs"] == 365
    end
  end

  defp applied_or_tableless?(row) do
    row.last_applied_status == "applied" or (row.last_applied_error || "") =~ "applies once"
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
