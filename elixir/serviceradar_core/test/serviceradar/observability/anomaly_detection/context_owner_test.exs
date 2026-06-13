defmodule ServiceRadar.Observability.AnomalyDetection.ContextOwnerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyDetection.ContextOwner

  test "folds clean samples into an immutable context for the next reasoner call" do
    {:ok, pid} = start_owner()

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e2", 2, 11.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.context.baseline == [10.0, 11.0]
    assert snapshot.context.consecutive_anomalous == 0
    assert Map.keys(snapshot.verdicts) == ["e1", "e2"]
  end

  test "duplicate event IDs are idempotent" do
    {:ok, pid} = start_owner()

    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("same-event", 1, 10.0))
    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("same-event", 1, 99.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.context.baseline == [10.0]
    assert snapshot.event_ids == ["same-event"]
  end

  test "out-of-order arrival is folded in temporal order" do
    {:ok, pid} = start_owner()

    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("late", 2, 20.0))
    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("early", 1, 10.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.event_ids == ["early", "late"]
    assert snapshot.context.baseline == [10.0, 20.0]
  end

  test "UUIDv8 order keys make out-of-order replays deterministic" do
    {:ok, pid} = start_owner()

    newer = "00000645-50df-8e80-8000-000000000002"
    older = "00000645-50de-8e80-8000-000000000001"

    assert {:ok, _verdict} = ContextOwner.evaluate(pid, uuid_sample(newer, 2, 20.0))
    assert {:ok, _verdict} = ContextOwner.evaluate(pid, uuid_sample(older, 1, 10.0))
    assert {:ok, _verdict} = ContextOwner.evaluate(pid, uuid_sample(older, 1, 99.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.event_ids == [older, newer]
    assert snapshot.context.baseline == [10.0, 20.0]
  end

  test "normalizes mixed binary and tuple order keys by timestamp" do
    {:ok, pid} = start_owner()

    assert {:ok, _verdict} =
             ContextOwner.evaluate(pid, %{
               sample("binary-key", 1, 10.0)
               | order_key: "00000645-50de-8e80-8000-000000000001"
             })

    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("tuple-key", 2, 20.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.event_ids == ["binary-key", "tuple-key"]
    assert snapshot.context.baseline == [10.0, 20.0]
  end

  test "withholds breached samples from the baseline and carries the consecutive counter" do
    {:ok, pid} = start_owner(reasoner: __MODULE__.WithholdReasoner)

    assert {:ok, %{state: "pending_anomaly"}} =
             ContextOwner.evaluate(pid, sample("breach", 1, 100.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.context.baseline == []
    assert snapshot.context.consecutive_anomalous == 1
  end

  test "in-order appends fold only the new sample" do
    Process.register(self(), __MODULE__.RecordingSink)
    {:ok, pid} = start_owner(reasoner: __MODULE__.RecordingReasoner)

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert_receive {:reasoned, [], 10.0}

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e2", 2, 11.0))
    assert_receive {:reasoned, [10.0], 11.0}
    refute_receive {:reasoned, [], 10.0}
  end

  test "late inserts re-reason only the affected suffix" do
    Process.register(self(), __MODULE__.RecordingSink)
    {:ok, pid} = start_owner(reasoner: __MODULE__.RecordingReasoner)

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert_receive {:reasoned, [], 10.0}

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e3", 3, 30.0))
    assert_receive {:reasoned, [10.0], 30.0}

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e5", 5, 50.0))
    assert_receive {:reasoned, [10.0, 30.0], 50.0}

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e4", 4, 40.0))

    assert_receive {:reasoned, [10.0, 30.0], 40.0}
    assert_receive {:reasoned, [10.0, 30.0, 40.0], 50.0}
    refute_receive {:reasoned, [], 10.0}
    refute_receive {:reasoned, [10.0], 30.0}

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.event_ids == ["e1", "e3", "e4", "e5"]
    assert snapshot.context.baseline == [10.0, 30.0, 40.0, 50.0]
  end

  test "late samples outside a full window are dropped explicitly" do
    {:ok, pid} = start_owner(max_events: 2)

    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("e2", 2, 20.0))
    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("e3", 3, 30.0))

    assert {:drop, :outside_window} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))

    snapshot = ContextOwner.snapshot(pid)
    assert snapshot.event_ids == ["e2", "e3"]
    assert snapshot.context.baseline == [20.0, 30.0]
  end

  test "rehydrates from checkpoint when a replacement owner starts" do
    series_key = "series-handoff-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{} end)

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.AgentCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      min_samples: 2
    ]

    {:ok, pid} = start_owner(opts)

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e2", 2, 11.0))

    GenServer.stop(pid)

    {:ok, replacement} = start_owner(opts)
    snapshot = ContextOwner.snapshot(replacement)

    assert snapshot.checkpoint_restored?
    assert snapshot.event_ids == ["e1", "e2"]
    assert snapshot.context.baseline == [10.0, 11.0]

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(replacement, sample("e3", 3, 12.0))
    assert ContextOwner.snapshot(replacement).context.baseline == [10.0, 11.0, 12.0]
  end

  test "handoff returns checkpointed replay verdicts without resaving duplicate events" do
    series_key = "series-replay-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{checkpoints: %{}, saves: %{}} end)

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.CountingCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      min_samples: 2
    ]

    {:ok, pid} = start_owner(opts)

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e2", 2, 11.0))
    assert __MODULE__.CountingCheckpoint.save_count(checkpoint_agent, series_key) == 2

    GenServer.stop(pid)

    {:ok, replacement} = start_owner(opts)
    snapshot = ContextOwner.snapshot(replacement)

    assert snapshot.checkpoint_restored?
    assert snapshot.context.baseline == [10.0, 11.0]

    assert {:ok, %{state: "clean"}} =
             ContextOwner.evaluate(replacement, %{sample("e1", 1, 999.0) | order_key: {9, "e1"}})

    assert __MODULE__.CountingCheckpoint.save_count(checkpoint_agent, series_key) == 2
    assert ContextOwner.snapshot(replacement).context.baseline == [10.0, 11.0]
  end

  test "checkpoint replay preserves anomalous verdict evidence after JSON restore" do
    series_key = "series-verdict-replay-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{} end)

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.JsonCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      reasoner: __MODULE__.FullAnomalyReasoner,
      suppress_until_warmed?: false
    ]

    {:ok, pid} = start_owner(opts)

    assert {:ok, %{state: "anomalous", anomalous: true, score: 3.8}} =
             ContextOwner.evaluate(
               pid,
               uuid_sample("00000645-50df-8e80-8000-000000000010", 1, 97.5)
             )

    GenServer.stop(pid)

    {:ok, replacement} = start_owner(opts)

    assert {:ok, verdict} =
             ContextOwner.evaluate(
               replacement,
               uuid_sample("00000645-50df-8e80-8000-000000000010", 1, 12.0)
             )

    assert verdict.state == "anomalous"
    assert verdict.anomalous == true
    assert verdict.breached == true
    assert verdict.score == 3.8
    assert verdict.baseline_count == 48
    assert verdict.sample_value == 97.5
    assert verdict.observed_at_unix_nano == 1
    assert [%{name: "rolling"} = signal] = verdict.signals
    assert signal.ready == true
    assert signal.breached == true
    assert signal.score == 3.8
    assert Map.has_key?(signal, :mean)
    assert signal.mean == nil
  end

  test "seeds cold baselines through SRQL and suppresses anomalous findings until rewarmed" do
    {:ok, pid} =
      start_owner(
        series_key: "series-1",
        min_samples: 2,
        reasoner: __MODULE__.AnomalyReasoner,
        baseline_seeder: ServiceRadar.Observability.AnomalyDetection.BaselineSeeder,
        baseline_seed_opts: [
          enabled: true,
          runner: __MODULE__.SRQLRunner,
          runner_opts: [test_pid: self()],
          query_templates: %{
            "test" =>
              ~S|in:timeseries_metrics series_key:"{{series_key}}" time:last_7d stats:"avg(value) as avg_value"|
          },
          reverse_rows: false
        ]
      )

    assert {:ok,
            %{
              state: "warming",
              anomalous: false,
              suppressed: true,
              suppressed_state: "anomaly"
            }} = ContextOwner.evaluate(pid, sample("e1", 1, 100.0))

    assert_received {:srql_query, query}
    assert String.contains?(query, ~s(series_key:"series-1"))

    snapshot = ContextOwner.snapshot(pid)
    assert snapshot.base_context.baseline == [8.0, 9.0]
    assert snapshot.live_update_count == 1

    assert {:ok, %{state: "anomaly", anomalous: true}} =
             ContextOwner.evaluate(pid, sample("e2", 2, 101.0))

    refute_receive {:srql_query, _query}, 50
  end

  test "applies per-series config before invoking the reasoner" do
    {:ok, pid} =
      start_owner(
        reasoner: __MODULE__.ConfiguredReasoner,
        series_config_opts: [
          series_overrides: %{
            "series-1" => %{
              n_sigma: 4.5,
              confirm_slots: 2,
              window_size: 12,
              min_samples: 3,
              seasonal_enabled: true,
              seasonal_sensitivity: 1.5
            }
          }
        ]
      )

    assert {:ok, %{state: "configured"}} =
             ContextOwner.evaluate(pid, sample("configured", 1, 10.0))

    context = ContextOwner.snapshot(pid).base_context
    assert context.n_sigma == 4.5
    assert context.confirm_slots == 2
    assert context.window_size == 12
    assert context.min_samples == 3
    assert context.seasonal_enabled
    assert context.seasonal_sensitivity == 1.5
    assert_in_delta context.seasonal_n_sigma, 3.0, 0.0001
    assert context.metric_group == "red"
    assert ContextOwner.snapshot(pid).series_config_applied?
  end

  defmodule CleanReasoner do
    @moduledoc false
    def reason(_context, _sample) do
      {:ok, %{state: "clean", include_in_baseline: true, next_consecutive_anomalous: 0}}
    end
  end

  defmodule WithholdReasoner do
    @moduledoc false
    def reason(_context, _sample) do
      {:ok,
       %{state: "pending_anomaly", include_in_baseline: false, next_consecutive_anomalous: 1}}
    end
  end

  defmodule RecordingReasoner do
    @moduledoc false
    @sink ServiceRadar.Observability.AnomalyDetection.ContextOwnerTest.RecordingSink

    def reason(context, sample) do
      send(Process.whereis(@sink), {
        :reasoned,
        context.baseline,
        sample.value
      })

      {:ok, %{state: "clean", include_in_baseline: true, next_consecutive_anomalous: 0}}
    end
  end

  defmodule AnomalyReasoner do
    @moduledoc false
    def reason(_context, _sample) do
      {:ok, %{state: "anomaly", anomalous: true, include_in_baseline: false}}
    end
  end

  defmodule FullAnomalyReasoner do
    @moduledoc false

    def reason(_context, sample) do
      {:ok,
       %{
         state: "anomalous",
         anomalous: true,
         breached: true,
         include_in_baseline: false,
         next_consecutive_anomalous: 5,
         score: 3.8,
         reason: "rolling z-score breached",
         baseline_count: 48,
         sample_value: sample.value,
         observed_at_unix_nano: sample.observed_at_unix_nano,
         signals: [
           %{
             name: "rolling",
             enabled: true,
             ready: true,
             breached: true,
             score: 3.8,
             threshold: 3.0,
             sample_count: 48,
             mean: nil,
             stddev: 15.0,
             reason: "breached"
           }
         ]
       }}
    end
  end

  defmodule ConfiguredReasoner do
    @moduledoc false

    def reason(
          %{
            n_sigma: 4.5,
            confirm_slots: 2,
            window_size: 12,
            min_samples: 3,
            seasonal_enabled: true
          },
          _sample
        ) do
      {:ok, %{state: "configured", include_in_baseline: true, next_consecutive_anomalous: 0}}
    end
  end

  defmodule AgentCheckpoint do
    @moduledoc false
    def load(series_key, opts) do
      opts
      |> Keyword.fetch!(:agent)
      |> Agent.get(&Map.get(&1, series_key))
      |> case do
        nil -> {:ok, nil}
        checkpoint -> {:ok, checkpoint}
      end
    end

    def save(series_key, checkpoint, opts) do
      opts
      |> Keyword.fetch!(:agent)
      |> Agent.update(&Map.put(&1, series_key, checkpoint))

      :ok
    end
  end

  defmodule JsonCheckpoint do
    @moduledoc false

    def load(series_key, opts) do
      opts
      |> Keyword.fetch!(:agent)
      |> Agent.get(&Map.get(&1, series_key))
      |> case do
        nil -> {:ok, nil}
        checkpoint -> {:ok, Jason.decode!(checkpoint)}
      end
    end

    def save(series_key, checkpoint, opts) do
      encoded = Jason.encode!(checkpoint)

      opts
      |> Keyword.fetch!(:agent)
      |> Agent.update(&Map.put(&1, series_key, encoded))

      :ok
    end
  end

  defmodule CountingCheckpoint do
    @moduledoc false

    def load(series_key, opts) do
      opts
      |> Keyword.fetch!(:agent)
      |> Agent.get(&Map.get(&1.checkpoints, series_key))
      |> case do
        nil -> {:ok, nil}
        checkpoint -> {:ok, checkpoint}
      end
    end

    def save(series_key, checkpoint, opts) do
      opts
      |> Keyword.fetch!(:agent)
      |> Agent.update(fn state ->
        %{
          state
          | checkpoints: Map.put(state.checkpoints, series_key, checkpoint),
            saves: Map.update(state.saves, series_key, 1, &(&1 + 1))
        }
      end)

      :ok
    end

    def save_count(agent, series_key) do
      Agent.get(agent, &Map.get(&1.saves, series_key, 0))
    end
  end

  defmodule SRQLRunner do
    @moduledoc false
    def query(query, opts) do
      opts
      |> Keyword.fetch!(:test_pid)
      |> send({:srql_query, query})

      {:ok, [%{"avg_value" => 8.0}, %{"avg_value" => 9.0}]}
    end
  end

  defp start_owner(opts \\ []) do
    ContextOwner.start_link(
      Keyword.merge(
        [
          series_key: "series-#{System.unique_integer([:positive])}",
          name: nil,
          reasoner: __MODULE__.CleanReasoner,
          series_config_opts: []
        ],
        opts
      )
    )
  end

  defp sample(event_id, order, value) do
    %{
      series_key: "series-1",
      event_id: event_id,
      order_key: {order, event_id},
      value: value,
      observed_at_unix_nano: order,
      subject: "otel.metrics.derived",
      metric_class: "test"
    }
  end

  defp uuid_sample(event_id, observed_at_unix_nano, value) do
    %{
      series_key: "series-1",
      event_id: event_id,
      order_key: event_id,
      value: value,
      observed_at_unix_nano: observed_at_unix_nano,
      subject: "otel.metrics.derived",
      metric_class: "test"
    }
  end
end
