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

    # Production default confirm_slots is 2 (task 1.16 / D-Q3). The behaviour tests in
    # this module exercise single-breach surfacing of OTHER concerns (SRQL profile/paging,
    # median/MAD robustness, clear emission, emission resilience), so pin their default to
    # 1; the confirm-slot HYSTERESIS itself is covered by the dedicated confirm_slots:1/3
    # tests below, which set their own runtime config and override this.
    AnomalyConfigRuntime.put_cache_for_test(%{seasonal_disposition_opts: [confirm_slots: 1]})

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
      series_keys = Enum.map(keys, &elem(&1, 0))

      states =
        :seasonal_state_store
        |> Process.get(%{})
        |> Map.values()
        |> Enum.group_by(&elem(&1.key, 0))
        |> Map.take(series_keys)
        |> Map.new(fn {series, actions} ->
          ordered = Enum.sort_by(actions, &DateTime.to_unix(&1.bucket_started_at), :desc)
          [latest | _] = ordered
          terminal = Enum.find(ordered, &(&1.status in ["normal", "cleared", "breach"]))

          {series,
           %{
             consecutive_anomalous: latest.consecutive_anomalous,
             disposition: latest.disposition,
             bucket_started_at: latest.bucket_started_at,
             # Postgrex timestamps have microsecond precision even at an exact second.
             bucket_ended_at: %{latest.bucket_ended_at | microsecond: {0, 6}},
             previously_confirmed: match?(%{status: "breach"}, terminal)
           }}
        end)

      {:ok, states}
    end

    def persist_many(_source, actions, _opts) do
      state =
        Enum.reduce(actions, Process.get(:seasonal_state_store, %{}), fn action, acc ->
          Map.put(acc, action.key, action)
        end)

      Process.put(:seasonal_state_store, state)
      :ok
    end
  end

  defmodule RecordingStateStore do
    @moduledoc false

    def load_many(_source, keys, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:seasonal_state_load, keys})
      {:ok, %{}}
    end

    def persist_many(_source, actions, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:seasonal_state_actions, actions})
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
      for _ <- 1..2 do
        assert_receive {:seasonal_query, query}
        query
      end

    assert Enum.all?(queries, &String.contains?(&1, ~s|timezone:"America/Chicago"|))
    refute Enum.any?(queries, &String.contains?(&1, ~s|timezone:"Etc/UTC"|))
  end

  test "edge baseline fetch forces UTC even when the profile timezone is non-UTC" do
    [source | _] =
      [seasonal_profile_timezone: "America/Chicago"]
      |> Source.defaults()
      |> Enum.map(&Source.from_config/1)
      |> Enum.filter(&Source.seasonal_disposition_supported?/1)

    # The central verdict query keeps the configured tz...
    assert String.contains?(source.query, ~s|timezone:"America/Chicago"|)

    # ...but the edge baseline is forced to UTC so its (dow,hod) buckets align with the
    # edge detector's UTC hour-of-week — a non-UTC profile would otherwise resolve no
    # bucket at the edge.
    assert {:ok, _rows} = Worker.edge_baseline_rows(source, runner: QueryRecorderRunner)

    assert_receive {:seasonal_query, query}
    assert String.contains?(query, ~s|timezone:"Etc/UTC"|)
    refute String.contains?(query, ~s|timezone:"America/Chicago"|)
  end

  test "edge baseline fetch enforces UTC even when the source query has no timezone term" do
    # `source/0` carries a profile query with NO `timezone:"..."` literal — a plain
    # Regex.replace would silently no-op and leave the baseline on SRQL's implicit tz.
    src = source()
    refute String.contains?(src.query, "timezone:")

    assert {:ok, _rows} = Worker.edge_baseline_rows(src, runner: QueryRecorderRunner)

    assert_receive {:seasonal_query, query}
    assert String.contains?(query, ~s|timezone:"Etc/UTC"|)
  end

  test "worker skips unsupported seasonal sources instead of claiming coverage" do
    event = [:serviceradar, :observability, :seasonal_disposition, :source_skipped]
    handler_id = {:seasonal_source_skipped, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {handler_id, measurements, metadata})
      end,
      nil
    )

    result =
      try do
        Worker.run(job(),
          sources: [
            %Source{
              name: "disk_seasonal",
              resource_type: "disk",
              metric_class: "disk",
              metric_name: "usage_percent",
              query: ~s|in:timeseries_metrics metric_type:"sysmon.disk"|
            },
            %Source{
              name: "snmp_interface_seasonal",
              resource_type: "interface",
              metric_class: "snmp",
              metric_name: "ifInOctets",
              query: ~s|in:timeseries_metrics metric_type:"snmp.interface"|
            }
          ],
          runner: QueryRecorderRunner
        )
      after
        :telemetry.detach(handler_id)
      end

    assert result == :ok
    refute_received {:seasonal_query, _}

    assert_receive {^handler_id, %{count: 1},
                    %{
                      source: "disk_seasonal",
                      metric_class: "disk",
                      reason: :unsupported_metric_class
                    }}

    assert_receive {^handler_id, %{count: 1},
                    %{
                      source: "snmp_interface_seasonal",
                      metric_class: "snmp",
                      reason: :unsupported_metric_class
                    }}
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

  defmodule MissingNifReasoner do
    @moduledoc false
    def dispose_batch(_kind, _inputs), do: :erlang.nif_error(:nif_not_loaded)
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
    assert measurements.covered == 2
    assert measurements.breached == 1
    assert measurements.suppressed == 1
    assert measurements.nif_duration_us >= 0
  end

  test "worker persists non-surfacing normal dispositions in state store" do
    busy = for i <- 0..19, do: 800.0 + rem(i, 5) * 2.0
    rows = [profile_row("svc/cpu/normal", 2, 9, busy, 805.0)]

    assert :ok =
             Worker.run(job(),
               sources: [source()],
               runner: make_runner(rows),
               state_store: RecordingStateStore,
               verdict_emitter: TestEmitter,
               test_pid: self()
             )

    assert_received {:seasonal_state_load, [{"svc/cpu/normal", 2, 9}]}
    assert_received {:seasonal_state_actions, [action]}

    assert action.key == {"svc/cpu/normal", 2, 9}
    assert action.disposition == "normal"
    assert action.status == "normal"
    assert action.consecutive_anomalous == 0
    assert action.evaluated_at == @evaluated_at
    assert is_number(action.score)
    assert action.bucket_started_at == ~U[2026-06-11 18:00:00Z]
    assert action.bucket_ended_at == ~U[2026-06-11 19:00:00Z]

    refute_received {:seasonal_verdict, _}
  end

  test "worker emits degraded liveness when seasonal NIF is unavailable" do
    event = [:serviceradar, :observability, :seasonal_disposition, :nif_liveness]
    handler_id = {:seasonal_nif_liveness, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {handler_id, measurements, metadata})
      end,
      nil
    )

    result =
      try do
        Worker.run(job(),
          reasoner: MissingNifReasoner,
          runner: QueryRecorderRunner
        )
      after
        :telemetry.detach(handler_id)
      end

    assert {:error, {:seasonal_nif_unavailable, {:nif_call_failed, _}}} = result

    assert_receive {^handler_id, %{count: 1},
                    %{status: :degraded, reason_class: "nif_call_failed"}}

    refute_received {:seasonal_query, _}
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

  test "worker confirms the first breach when confirm_slots is one" do
    AnomalyConfigRuntime.put_cache_for_test(%{
      seasonal_disposition_opts: [confirm_slots: 1]
    })

    idle = for i <- 0..19, do: 5.0 + rem(i, 3) * 0.5
    rows = [profile_row("svc/cpu/first-breach", 0, 3, idle, 800.0)]

    assert :ok =
             Worker.run(job(),
               sources: [source()],
               runner: make_runner(rows),
               carried_state: %{},
               verdict_emitter: TestEmitter,
               test_pid: self()
             )

    assert_received {:seasonal_verdict, attrs}
    assert attrs.series_key == "svc/cpu/first-breach"
    assert attrs.disposition == "seasonal_breach"
    assert attrs.consecutive_anomalous == 1
  end

  test "worker confirms adjacent hourly buckets across midnight and clears the next clean hour" do
    AnomalyConfigRuntime.put_cache_for_test(%{
      seasonal_disposition_opts: [confirm_slots: 3]
    })

    for hour <- 0..1 do
      assert :ok = run_window(chronological_row("svc/cpu/restart", hour, 45.0))
      refute_received {:seasonal_verdict, _}
    end

    assert :ok = run_window(chronological_row("svc/cpu/restart", 2, 45.0))
    assert_received {:seasonal_verdict, %{status: "breach", consecutive_anomalous: 3}}

    assert :ok = run_window(chronological_row("svc/cpu/restart", 3, 12.5))
    assert_received {:seasonal_verdict, %{status: "cleared", consecutive_anomalous: 0}}
  end

  test "same and older buckets neither confirm nor change committed state" do
    AnomalyConfigRuntime.put_cache_for_test(%{seasonal_disposition_opts: [confirm_slots: 2]})
    first = chronological_row("svc/cpu/retry", 0, 45.0)
    second = chronological_row("svc/cpu/retry", 1, 45.0)

    assert :ok = run_window(first)
    pending = Process.get(:seasonal_state_store)
    assert :ok = run_window(first)
    assert Process.get(:seasonal_state_store) == pending
    refute_received {:seasonal_verdict, _}

    assert :ok = run_window(second)
    assert_received {:seasonal_verdict, %{status: "breach", consecutive_anomalous: 2}}
    confirmed = Process.get(:seasonal_state_store)

    assert :ok = run_window(second)
    assert :ok = run_window(first)
    assert Process.get(:seasonal_state_store) == confirmed
    refute_received {:seasonal_verdict, _}
  end

  test "a gap or the same hour next week cannot complete confirmation" do
    AnomalyConfigRuntime.put_cache_for_test(%{seasonal_disposition_opts: [confirm_slots: 2]})

    for hour <- [0, 2, 170] do
      assert :ok = run_window(chronological_row("svc/cpu/gap", hour, 45.0))
      refute_received {:seasonal_verdict, _}
    end

    assert Enum.all?(Process.get(:seasonal_state_store), fn {_key, state} ->
             state.consecutive_anomalous == 1
           end)
  end

  test "insufficient history breaks confirmation without clearing an open breach" do
    AnomalyConfigRuntime.put_cache_for_test(%{seasonal_disposition_opts: [confirm_slots: 2]})

    assert :ok = run_window(chronological_row("svc/cpu/thin", 0, 45.0))
    assert :ok = run_window(chronological_row("svc/cpu/thin", 1, 45.0, [10.0]))
    assert :ok = run_window(chronological_row("svc/cpu/thin", 2, 45.0))
    refute_received {:seasonal_verdict, _}

    assert :ok = run_window(chronological_row("svc/cpu/thin", 3, 45.0))
    assert_received {:seasonal_verdict, %{status: "breach", consecutive_anomalous: 2}}

    assert :ok = run_window(chronological_row("svc/cpu/thin", 4, 45.0, [10.0]))
    refute_received {:seasonal_verdict, _}
    assert :ok = run_window(chronological_row("svc/cpu/thin", 5, 12.5))
    assert_received {:seasonal_verdict, %{status: "cleared", consecutive_anomalous: 0}}
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
    event = [:serviceradar, :observability, :seasonal_disposition, :source]
    handler_id = {:seasonal_thin_bucket, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {handler_id, measurements, metadata})
      end,
      nil
    )

    rows = [profile_row("svc/cpu/thin", 1, 4, [10.0, 11.0, 9.0], 50.0)]

    result =
      try do
        Worker.run(job(),
          sources: [source()],
          runner: make_runner(rows),
          verdict_emitter: TestEmitter,
          test_pid: self()
        )
      after
        :telemetry.detach(handler_id)
      end

    assert result == :ok
    refute_received {:seasonal_verdict, _}
    assert_receive {^handler_id, measurements, %{source: "cpu_seasonal", result: :ok}}
    assert measurements.evaluated == 1
    assert measurements.covered == 0
    assert measurements.insufficient == 1
  end

  test "worker treats sparse robust profile nulls as insufficient history" do
    robust_source = %{source() | robust_statistic: :median_mad}

    rows = [
      %{
        "series" => "svc/cpu/sparse-robust",
        "dow" => 0,
        "hod" => 3,
        "sample_value" => 800.0,
        "bucket_count" => 1,
        "center" => nil,
        "mad" => nil,
        "bucket" => ~U[2026-06-07 03:00:00Z]
      }
    ]

    assert :ok =
             Worker.run(job(),
               sources: [robust_source],
               runner: make_runner(rows),
               verdict_emitter: TestEmitter,
               test_pid: self()
             )

    refute_received {:seasonal_verdict, _}
  end

  test "median-mad profile resists a single poisoned historical hour in a five-sample cell" do
    robust_source = %{source() | robust_statistic: :median_mad}

    # Historical profile represented by SQL order stats for [10, 10, 11, 11, 500].
    # A mean/stddev baseline would be widened by the one historical incident; the
    # robust center/MAD keeps the current 60% sample visibly off-profile.
    rows = [
      %{
        "series" => "svc/cpu/poisoned-cell",
        "dow" => 0,
        "hod" => 3,
        "sample_value" => 60.0,
        "bucket_count" => 5,
        "center" => 11.0,
        "mad" => 1.0,
        "bucket" => ~U[2026-06-07 03:00:00Z]
      }
    ]

    assert :ok =
             Worker.run(job(),
               sources: [robust_source],
               runner: make_runner(rows),
               verdict_emitter: TestEmitter,
               test_pid: self()
             )

    assert_received {:seasonal_verdict, attrs}
    assert attrs.series_key == "svc/cpu/poisoned-cell"
    assert attrs.disposition == "seasonal_breach"
    assert attrs.metadata["robust_statistic"] == "median_mad"
  end

  test "robust baseline sufficiency counts historical samples without the evaluated sample" do
    for statistic <- [:median_mad, :p05p95] do
      robust_source = %{source() | robust_statistic: statistic}
      mature_series = "svc/cpu/#{statistic}/mature"

      rows =
        for {series, history_count} <- [
              {"svc/cpu/#{statistic}/sparse", 3},
              {mature_series, 4}
            ] do
          %{
            "series" => series,
            "dow" => 0,
            "hod" => 3,
            "sample_value" => 60.0,
            "bucket_count" => history_count + 1,
            "robust_bucket_count" => history_count,
            "center" => 10.0,
            "mad" => 1.0,
            "p05" => 8.0,
            "p95" => 12.0,
            "bucket" => ~U[2026-06-07 03:00:00Z]
          }
        end

      assert :ok =
               Worker.run(job(),
                 sources: [robust_source],
                 runner: make_runner(rows),
                 verdict_emitter: TestEmitter,
                 test_pid: self()
               )

      assert_received {:seasonal_verdict,
                       %{series_key: ^mature_series, disposition: "seasonal_breach"}}

      refute_received {:seasonal_verdict, _}
    end
  end

  test "robust hydration retains zero history and full-profile counts per hour-of-week cell" do
    robust_source = %{source() | robust_statistic: :median_mad}

    rows =
      for {hod, inclusive, historical} <- [{1, 1, 0}, {2, 5, 4}, {3, 5, 5}] do
        %{
          "series" => "svc/cpu/profile-counts",
          "dow" => 0,
          "hod" => hod,
          "sample_value" => 20.0,
          "bucket_count" => inclusive,
          "robust_bucket_count" => historical,
          "center" => if(historical == 0, do: nil, else: 10.0),
          "mad" => if(historical == 0, do: nil, else: 1.0),
          "bucket" => DateTime.add(~U[2026-06-07 00:00:00Z], hod * 3_600, :second)
        }
      end

    assert {:ok,
            [
              %{hod: 1, bucket_count: 0},
              %{hod: 2, bucket_count: 4},
              %{hod: 3, bucket_count: 5}
            ]} = Worker.edge_baseline_rows(robust_source, runner: make_runner(rows))
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

  test "failed publication leaves the bucket uncommitted so retry delivers its verdict" do
    idle = for i <- 0..19, do: 5.0 + rem(i, 3) * 0.5
    rows = [profile_row("svc/cpu/x", 0, 3, idle, 800.0)]

    log =
      capture_log(fn ->
        assert {:error, {:seasonal_verdict_emit_failed, {:error, _}}} =
                 Worker.run(job(),
                   sources: [source()],
                   runner: make_runner(rows),
                   verdict_emitter: FailingEmitter,
                   test_pid: self()
                 )
      end)

    assert_received {:seasonal_verdict_attempt, %{series_key: "svc/cpu/x"}}
    assert log =~ "Seasonal disposition verdict emit failed"
    assert Process.get(:seasonal_state_store, %{}) == %{}

    assert :ok = run_window(hd(rows))
    assert_received {:seasonal_verdict, %{series_key: "svc/cpu/x", status: "breach"}}
    assert :ok = run_window(hd(rows))
    refute_received {:seasonal_verdict, _}
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

  defp chronological_row(series, hour, value, baseline \\ [10.0, 11.0, 12.0, 13.0, 14.0, 15.0]) do
    bucket = DateTime.add(~U[2026-01-04 23:00:00Z], hour * 3_600, :second)
    dow = rem(Date.day_of_week(DateTime.to_date(bucket)), 7)

    series
    |> profile_row(dow, bucket.hour, baseline, value)
    |> Map.put("bucket", bucket)
  end

  defp run_window(row) do
    Worker.run(job(),
      sources: [source()],
      runner: make_runner([row]),
      verdict_emitter: TestEmitter,
      test_pid: self()
    )
  end
end
