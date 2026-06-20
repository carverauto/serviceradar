defmodule ServiceRadar.Observability.SeasonalDisposition.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Observability.SeasonalDisposition.Worker

  @evaluated_at ~U[2026-06-12 12:00:00Z]
  @bucket_at ~U[2026-06-09 09:00:00Z]

  setup do
    previous_worker_config = Application.get_env(:serviceradar_core, Worker, [])

    Application.put_env(
      :serviceradar_core,
      Worker,
      Keyword.put(previous_worker_config, :state_store, __MODULE__.ProcessStateStore)
    )

    Process.delete(:seasonal_state_store)
    AnomalyConfigRuntime.clear_cache_for_test()

    on_exit(fn ->
      if previous_worker_config == [] do
        Application.delete_env(:serviceradar_core, Worker)
      else
        Application.put_env(:serviceradar_core, Worker, previous_worker_config)
      end

      AnomalyConfigRuntime.clear_cache_for_test()
    end)
  end

  defmodule ProcessStateStore do
    @moduledoc false

    def load_many(_source, keys, _opts) do
      state = Process.get(:seasonal_state_store, %{})
      {:ok, Map.take(state, keys)}
    end

    def persist_many(_source, actions, _opts) do
      state =
        Enum.reduce(actions, Process.get(:seasonal_state_store, %{}), fn action, acc ->
          Map.put(acc, action.key, action.consecutive_anomalous)
        end)

      Process.put(:seasonal_state_store, state)
      :ok
    end
  end

  test "manual enqueue uniqueness ignores per-run evaluated_at" do
    first =
      Worker.new(%{
        "trigger" => "manual",
        "evaluated_at" => "2026-06-12T12:00:00Z"
      })

    second =
      Worker.new(%{
        "trigger" => "manual",
        "evaluated_at" => "2026-06-12T12:05:00Z"
      })

    assert first.changes.unique.keys == [:trigger]
    assert second.changes.unique.keys == [:trigger]
    assert first.changes.unique.fields == [:args, :queue, :worker]
  end

  defmodule QueryRecorderRunner do
    @moduledoc false
    def query(query, _opts) do
      send(self(), {:seasonal_query, query})
      {:ok, []}
    end
  end

  test "runtime profile timezone is applied to default seasonal source queries" do
    AnomalyConfigRuntime.put_cache_for_test(%{
      seasonal_disposition_opts: [seasonal_profile_timezone: "America/Chicago"]
    })

    assert :ok = Worker.run(job(), runner: QueryRecorderRunner)

    queries =
      for _ <- 1..3 do
        assert_receive {:seasonal_query, query}
        query
      end

    assert Enum.all?(queries, &String.contains?(&1, ~s|timezone:"America/Chicago"|))
    refute Enum.any?(queries, &String.contains?(&1, ~s|timezone:"Etc/UTC"|))
  end

  # A profile row carrying the SQL-aggregated (dow,hod) bucket summary INCLUDING the
  # sample under test (the natural CAGG aggregate the mean/stddev kernel de-aggregates).
  defp profile_row(series, dow, hod, baseline_points, sample_value) do
    sum = sample_value + Enum.sum(baseline_points)
    sum_sq = sample_value * sample_value + Enum.reduce(baseline_points, 0.0, &(&2 + &1 * &1))

    %{
      "series" => series,
      "dow" => dow,
      "hod" => hod,
      "sample_value" => sample_value,
      "bucket_count" => length(baseline_points) + 1,
      "bucket_sum" => sum,
      "bucket_sum_sq" => sum_sq,
      "bucket" => DateTime.add(@bucket_at, dow * 86_400 + hod * 3_600, :second)
    }
  end

  defp source do
    %Source{
      name: "cpu_seasonal",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query:
        ~s|in:timeseries_metrics metric_type:"sysmon.cpu" time:last_180d bucket:1h stats:profile_hour_of_week(value)|,
      robust_statistic: :mean_stddev,
      label_fields: ["series"]
    }
  end

  defmodule BreachRunner do
    @moduledoc false
    # One off-season breach (Sunday-3am at busy-Tuesday levels), one in-season suppress.
    def query(query, _opts) do
      send(self(), {:seasonal_query, query})

      idle = for i <- 0..19, do: 5.0 + rem(i, 3) * 0.5
      busy = for i <- 0..19, do: 800.0 + rem(i, 5) * 2.0

      {:ok,
       [
         row("svc/cpu/a", 0, 3, idle, 800.0),
         row("svc/cpu/b", 2, 9, busy, 805.0)
       ]}
    end

    defp row(series, dow, hod, baseline, sample) do
      sum = sample + Enum.sum(baseline)
      sum_sq = sample * sample + Enum.reduce(baseline, 0.0, &(&2 + &1 * &1))

      %{
        "series" => series,
        "dow" => dow,
        "hod" => hod,
        "sample_value" => sample,
        "bucket_count" => length(baseline) + 1,
        "bucket_sum" => sum,
        "bucket_sum_sq" => sum_sq,
        "bucket" => ~U[2026-06-07 03:00:00Z]
      }
    end
  end

  defmodule TestEmitter do
    @moduledoc false
    def emit(attrs, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:seasonal_verdict, attrs})
      :ok
    end
  end

  defmodule FailingEmitter do
    @moduledoc false
    def emit(attrs, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:seasonal_verdict_attempt, attrs})
      {:error, {:nats_not_connected, :reconnecting}}
    end
  end

  test "worker reads the hour-of-week profile through SRQL and disposes via the NIF" do
    event = [:serviceradar, :observability, :seasonal_disposition, :source]
    handler_id = {:seasonal_source, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {handler_id, measurements, metadata})
      end,
      nil
    )

    persisted = :ets.new(:seasonal_state, [:public, :set])

    state_persister = fn key, next ->
      :ets.insert(persisted, {key, next})
      :ok
    end

    result =
      try do
        Worker.run(job(),
          sources: [source()],
          runner: BreachRunner,
          verdict_emitter: TestEmitter,
          state_persister: state_persister,
          test_pid: self()
        )
      after
        :telemetry.detach(handler_id)
      end

    assert result == :ok

    assert_received {:seasonal_query, query}
    assert query =~ "metric_type:\"sysmon.cpu\""

    # Only the off-season breach surfaces a verdict; the in-season row suppresses.
    assert_received {:seasonal_verdict, attrs}
    assert attrs.series_key == "svc/cpu/a"
    assert attrs.disposition == "seasonal_breach"
    assert attrs.status == "breach"
    assert attrs.score >= 3.0
    assert attrs.consecutive_anomalous == 1
    assert attrs.bucket_started_at == ~U[2026-06-07 03:00:00Z]
    assert attrs.bucket_ended_at == ~U[2026-06-07 04:00:00Z]
    assert attrs.metadata["verdict_source"] == "central-seasonal"
    refute_received {:seasonal_verdict, %{series_key: "svc/cpu/b"}}

    # Confirmed breach persists consecutive_anomalous = 1; the suppress resets to 0.
    assert [{_, 1}] = :ets.lookup(persisted, {"svc/cpu/a", 0, 3})
    assert [{_, 0}] = :ets.lookup(persisted, {"svc/cpu/b", 2, 9})

    assert_receive {^handler_id, measurements, %{source: "cpu_seasonal", result: :ok}}
    assert measurements.evaluated == 2
    assert measurements.breached == 1
    assert measurements.suppressed == 1
    assert measurements.nif_duration_us >= 0
  end

  test "worker carries consecutive_anomalous in for confirm-slot hysteresis" do
    test_pid = self()

    # confirm_slots = 3 via runtime config; a single over-threshold slot with no carried
    # history is a pending drift (no verdict). With 2 carried slots it confirms.
    AnomalyConfigRuntime.put_cache_for_test(%{
      seasonal_disposition_opts: [confirm_slots: 3]
    })

    runner = fn ->
      idle = for i <- 0..19, do: 5.0 + rem(i, 3) * 0.5
      [profile_row("svc/cpu/c", 0, 3, idle, 800.0)]
    end

    rows = runner.()

    page_runner = make_runner(rows)

    # First pass: no carried history → pending drift, no verdict.
    assert :ok =
             Worker.run(job(),
               sources: [source()],
               runner: page_runner,
               carried_state: %{},
               verdict_emitter: TestEmitter,
               test_pid: test_pid
             )

    refute_received {:seasonal_verdict, _}

    # Third pass: 2 carried slots → this is the 3rd over-threshold slot → confirmed breach.
    assert :ok =
             Worker.run(job(),
               sources: [source()],
               runner: page_runner,
               carried_state: %{{"svc/cpu/c", 0, 3} => 2},
               verdict_emitter: TestEmitter,
               test_pid: test_pid
             )

    assert_received {:seasonal_verdict, attrs}
    assert attrs.disposition == "seasonal_breach"
    assert attrs.consecutive_anomalous == 3
  end

  test "worker persists seasonal confirmation across independent runs" do
    test_pid = self()

    AnomalyConfigRuntime.put_cache_for_test(%{
      seasonal_disposition_opts: [confirm_slots: 3]
    })

    idle = for i <- 0..19, do: 5.0 + rem(i, 3) * 0.5
    rows = [profile_row("svc/cpu/restart", 0, 3, idle, 800.0)]
    page_runner = make_runner(rows)

    for _ <- 1..2 do
      assert :ok =
               Worker.run(job(),
                 sources: [source()],
                 runner: page_runner,
                 verdict_emitter: TestEmitter,
                 test_pid: test_pid
               )

      refute_received {:seasonal_verdict, _}
    end

    assert Process.get(:seasonal_state_store)[{"svc/cpu/restart", 0, 3}] == 2

    assert :ok =
             Worker.run(job(),
               sources: [source()],
               runner: page_runner,
               verdict_emitter: TestEmitter,
               test_pid: test_pid
             )

    assert_received {:seasonal_verdict, attrs}
    assert attrs.series_key == "svc/cpu/restart"
    assert attrs.disposition == "seasonal_breach"
    assert attrs.consecutive_anomalous == 3
    assert Process.get(:seasonal_state_store)[{"svc/cpu/restart", 0, 3}] == 3
  end

  test "worker resets pending confirmation on clean slot without emitting clear" do
    AnomalyConfigRuntime.put_cache_for_test(%{
      seasonal_disposition_opts: [confirm_slots: 3]
    })

    busy = for i <- 0..19, do: 800.0 + rem(i, 5) * 2.0
    rows = [profile_row("svc/cpu/pending-clean", 2, 9, busy, 805.0)]
    persisted = :ets.new(:seasonal_state_pending_clean, [:public, :set])

    assert :ok =
             Worker.run(job(),
               sources: [source()],
               runner: make_runner(rows),
               carried_state: %{{"svc/cpu/pending-clean", 2, 9} => 2},
               state_persister: fn key, next ->
                 :ets.insert(persisted, {key, next})
                 :ok
               end,
               verdict_emitter: TestEmitter,
               test_pid: self()
             )

    refute_received {:seasonal_verdict, _}
    assert [{_, 0}] = :ets.lookup(persisted, {"svc/cpu/pending-clean", 2, 9})
  end

  test "worker gates a thin bucket to insufficient without surfacing a verdict" do
    rows = [profile_row("svc/cpu/thin", 1, 4, [10.0, 11.0, 9.0], 50.0)]

    assert :ok =
             Worker.run(job(),
               sources: [source()],
               runner: make_runner(rows),
               verdict_emitter: TestEmitter,
               test_pid: self()
             )

    refute_received {:seasonal_verdict, _}
  end

  test "worker emits a clear when a previously confirmed seasonal breach suppresses" do
    busy = for i <- 0..19, do: 800.0 + rem(i, 5) * 2.0
    rows = [profile_row("svc/cpu/clear", 2, 9, busy, 805.0)]
    persisted = :ets.new(:seasonal_state_clear, [:public, :set])

    assert :ok =
             Worker.run(job(),
               sources: [source()],
               runner: make_runner(rows),
               carried_state: %{{"svc/cpu/clear", 2, 9} => 1},
               state_persister: fn key, next ->
                 :ets.insert(persisted, {key, next})
                 :ok
               end,
               verdict_emitter: TestEmitter,
               test_pid: self()
             )

    assert_received {:seasonal_verdict, attrs}
    assert attrs.series_key == "svc/cpu/clear"
    assert attrs.disposition == "suppress"
    assert attrs.status == "cleared"
    assert attrs.consecutive_anomalous == 0
    assert attrs.bucket_started_at == ~U[2026-06-11 18:00:00Z]
    assert attrs.bucket_ended_at == ~U[2026-06-11 19:00:00Z]
    assert [{_, 0}] = :ets.lookup(persisted, {"svc/cpu/clear", 2, 9})
  end

  test "worker pages profile rows instead of truncating at the first SRQL limit page" do
    idle = for i <- 0..19, do: 5.0 + rem(i, 3) * 0.5

    defmodule_paged = %{
      page1: [profile_row("svc/cpu/p1", 0, 3, idle, 800.0)],
      page2: [profile_row("svc/cpu/p2", 0, 3, idle, 800.0)]
    }

    page_runner = __MODULE__.PagedRunner
    Process.put(:paged_rows, defmodule_paged)

    persisted = :ets.new(:seasonal_state_paged, [:public, :set])

    assert :ok =
             Worker.run(job(),
               sources: [source()],
               runner: page_runner,
               verdict_emitter: TestEmitter,
               state_persister: fn key, next ->
                 :ets.insert(persisted, {key, next})
                 :ok
               end,
               test_pid: self()
             )

    # Both pages disposed → both breaches surfaced.
    assert_received {:seasonal_verdict, %{series_key: "svc/cpu/p1"}}
    assert_received {:seasonal_verdict, %{series_key: "svc/cpu/p2"}}
  end

  test "worker keeps disposing when verdict emission fails" do
    idle = for i <- 0..19, do: 5.0 + rem(i, 3) * 0.5
    rows = [profile_row("svc/cpu/x", 0, 3, idle, 800.0)]

    log =
      capture_log(fn ->
        assert :ok =
                 Worker.run(job(),
                   sources: [source()],
                   runner: make_runner(rows),
                   verdict_emitter: FailingEmitter,
                   test_pid: self()
                 )
      end)

    assert_received {:seasonal_verdict_attempt, %{series_key: "svc/cpu/x"}}
    assert log =~ "Seasonal disposition verdict emit failed"
  end

  test "worker returns an error when the profile query fails" do
    assert {:error, :db_down} =
             Worker.run(job(),
               sources: [source()],
               runner: __MODULE__.ErrorRunner,
               verdict_emitter: TestEmitter,
               test_pid: self()
             )
  end

  test "worker fails loudly when SRQL rows omit profile columns" do
    event = [:serviceradar, :observability, :seasonal_disposition, :source]
    handler_id = {:seasonal_profile_error, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {handler_id, measurements, metadata})
      end,
      nil
    )

    rows = [
      %{
        "series" => "svc/cpu/missing-profile",
        "dow" => 0,
        "hod" => 3,
        "sample_value" => 42.0,
        "bucket" => @bucket_at
      }
    ]

    log =
      try do
        capture_log(fn ->
          assert {:error, {:seasonal_profile_columns_missing, missing}} =
                   Worker.run(job(),
                     sources: [source()],
                     runner: make_runner(rows),
                     verdict_emitter: TestEmitter,
                     test_pid: self()
                   )

          assert "bucket_count" in missing
          assert "bucket_sum" in missing
          assert "bucket_sum_sq" in missing
        end)
      after
        :telemetry.detach(handler_id)
      end

    assert log =~ "Seasonal disposition profile rows missing required columns"
    refute_received {:seasonal_verdict, _}

    assert_receive {^handler_id, measurements,
                    %{source: "cpu_seasonal", phase: :profile, result: :error} = metadata}

    assert measurements.rows == 0
    assert metadata.reason_class == "seasonal_profile_columns_missing"
  end

  defmodule PagedRunner do
    @moduledoc false
    def query_page(query, opts) do
      cursor = Keyword.get(opts, :cursor)
      send(self(), {:seasonal_query_page, query, cursor})
      pages = Process.get(:paged_rows)

      case cursor do
        nil -> {:ok, %{rows: pages.page1, next_cursor: "page-2"}}
        "page-2" -> {:ok, %{rows: pages.page2, next_cursor: nil}}
      end
    end
  end

  defmodule ErrorRunner do
    @moduledoc false
    def query(_query, _opts), do: {:error, :db_down}
  end

  # Build an anonymous-module-free single-page runner that returns `rows`.
  defp make_runner(rows) do
    Process.put(:single_page_rows, rows)
    __MODULE__.SinglePageRunner
  end

  defmodule SinglePageRunner do
    @moduledoc false
    def query(_query, _opts), do: {:ok, Process.get(:single_page_rows)}
  end

  defp job do
    %Oban.Job{
      args: %{"trigger" => "cron"},
      inserted_at: @evaluated_at,
      scheduled_at: @evaluated_at
    }
  end
end
