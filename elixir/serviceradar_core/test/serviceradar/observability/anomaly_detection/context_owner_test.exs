defmodule ServiceRadar.Observability.AnomalyDetection.ContextOwnerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyDetection.ContextOwner

  test "folds clean samples into an immutable context for the next reasoner call" do
    {:ok, pid} = start_owner()

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e2", 2, 11.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.context.baseline == []
    assert snapshot.context.window_tail == [10.0, 11.0]
    assert snapshot.context.consecutive_anomalous == 0
    assert Map.keys(snapshot.verdicts) == ["e1", "e2"]
  end

  test "persists compact rolling state returned by the reasoner" do
    {:ok, pid} = start_owner(reasoner: __MODULE__.CompactStateReasoner, window_size: 2)

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e2", 2, 11.0))
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e3", 3, 12.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.context.baseline == []
    assert snapshot.context.window_tail == [11.0, 12.0]
    assert snapshot.context.rolling_acc.count == 2
    assert_in_delta snapshot.context.rolling_acc.mean, 11.5, 0.0001
    assert_in_delta snapshot.context.rolling_acc.m2, 0.5, 0.0001
  end

  test "duplicate event IDs are idempotent" do
    {:ok, pid} = start_owner()

    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("same-event", 1, 10.0))
    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("same-event", 1, 99.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.context.window_tail == [10.0]
    assert snapshot.event_ids == ["same-event"]
  end

  test "out-of-order arrival is folded in temporal order" do
    {:ok, pid} = start_owner()

    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("late", 2, 20.0))
    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("early", 1, 10.0))

    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.event_ids == ["early", "late"]
    assert snapshot.context.window_tail == [10.0, 20.0]
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
    assert snapshot.context.window_tail == [10.0, 20.0]
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
    assert snapshot.context.window_tail == [10.0, 20.0]
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
    assert snapshot.context.window_tail == [10.0, 30.0, 40.0, 50.0]
  end

  test "late samples outside a full window are dropped explicitly" do
    {:ok, pid} = start_owner(max_events: 2)

    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("e2", 2, 20.0))
    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("e3", 3, 30.0))

    assert {:drop, :outside_window} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))

    snapshot = ContextOwner.snapshot(pid)
    assert snapshot.event_ids == ["e2", "e3"]
    assert snapshot.context.window_tail == [20.0, 30.0]
  end

  test "rehydrates from checkpoint when a replacement owner starts" do
    series_key = "series-handoff-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{} end)

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.AgentCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      checkpoint_flush_interval_ms: 0,
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
    assert snapshot.context.window_tail == [10.0, 11.0]

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(replacement, sample("e3", 3, 12.0))
    assert ContextOwner.snapshot(replacement).context.window_tail == [10.0, 11.0, 12.0]
  end

  test "handoff returns checkpointed replay verdicts without resaving duplicate events" do
    series_key = "series-replay-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{checkpoints: %{}, saves: %{}} end)

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.CountingCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      checkpoint_flush_interval_ms: 0,
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
    assert snapshot.context.window_tail == [10.0, 11.0]

    assert {:ok, %{state: "clean"}} =
             ContextOwner.evaluate(replacement, %{sample("e1", 1, 999.0) | order_key: {9, "e1"}})

    assert __MODULE__.CountingCheckpoint.save_count(checkpoint_agent, series_key) == 2
    assert ContextOwner.snapshot(replacement).context.window_tail == [10.0, 11.0]
  end

  test "does not borrow base_context's acc when the checkpoint's context omits its own acc" do
    # Fix(review): window_tail and rolling_acc must be restored atomically from the
    # SAME checkpoint state. Here the checkpoint's `context` carries a window_tail of
    # length 3 but NO rolling_acc, while its `base_context` carries a count-3 acc with
    # a corrupt mean/m2 (e.g. from a different window). The previous code restored
    # window_tail from `context` but fell back to `base_context`'s acc; since the
    # NIF's valid_for_count is count-only, that count-3 corrupt acc would be trusted
    # and install a corrupt baseline. The owner must instead set rolling_acc to nil so
    # the NIF recomputes from window_tail.
    series_key = "series-cross-source-acc-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{} end)

    window_tail = [10.0, 11.0, 12.0]
    # Count matches length(window_tail) so the count-only NIF check would accept it,
    # but the mean/m2 are deliberately wrong for [10.0, 11.0, 12.0].
    corrupt_acc = %{count: 3, mean: 999.0, m2: 4242.0}

    base_context = %{
      baseline: [],
      window_tail: window_tail,
      rolling_acc: corrupt_acc,
      min_samples: 2,
      window_size: 3,
      n_sigma: 3.0,
      confirm_slots: 5,
      consecutive_anomalous: 0
    }

    # context omits rolling_acc entirely; only window_tail is present.
    context = Map.delete(base_context, :rolling_acc)

    checkpoint = %{
      version: 1,
      series_key: series_key,
      updates: [],
      verdicts: %{},
      base_context: base_context,
      context: context
    }

    Agent.update(checkpoint_agent, &Map.put(&1, series_key, checkpoint))

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.AgentCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      checkpoint_flush_interval_ms: 0,
      reasoner: __MODULE__.CompactStateReasoner,
      window_size: 3,
      min_samples: 2
    ]

    {:ok, pid} = start_owner(opts)
    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.checkpoint_restored?
    assert snapshot.context.window_tail == window_tail
    # The corrupt cross-source acc is NOT borrowed; the NIF recomputes from window_tail.
    assert snapshot.context.rolling_acc == nil

    # Folding the next sample produces the correct baseline (count 3 over the window
    # [11.0, 12.0, 13.0]), not one tainted by the corrupt mean/m2.
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e4", 4, 13.0))

    acc = ContextOwner.snapshot(pid).context.rolling_acc
    assert acc.count == 3
    assert_in_delta acc.mean, 12.0, 0.0001
    assert_in_delta acc.m2, 2.0, 0.0001
  end

  test "drops a restored acc whose count disagrees with the restored window_tail length" do
    # Fix(review): even a rolling_acc present in the same checkpoint state must be
    # dropped when its count does not match the (possibly truncated) window_tail it
    # pairs with. Here window_size=3 truncates the 4-element window_tail to length 3,
    # but the persisted acc claims count 4. The owner sets rolling_acc to nil so the
    # NIF recomputes from the truncated window_tail.
    series_key = "series-count-mismatch-acc-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{} end)

    context = %{
      baseline: [],
      window_tail: [9.0, 10.0, 11.0, 12.0],
      rolling_acc: %{count: 4, mean: 10.5, m2: 5.0},
      min_samples: 2,
      window_size: 3,
      n_sigma: 3.0,
      confirm_slots: 5,
      consecutive_anomalous: 0
    }

    checkpoint = %{
      version: 1,
      series_key: series_key,
      updates: [],
      verdicts: %{},
      base_context: context,
      context: context
    }

    Agent.update(checkpoint_agent, &Map.put(&1, series_key, checkpoint))

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.AgentCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      checkpoint_flush_interval_ms: 0,
      reasoner: __MODULE__.CompactStateReasoner,
      window_size: 3,
      min_samples: 2
    ]

    {:ok, pid} = start_owner(opts)
    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.checkpoint_restored?
    # window_tail truncated to window_size (3); acc count 4 no longer matches.
    assert snapshot.context.window_tail == [10.0, 11.0, 12.0]
    assert snapshot.context.rolling_acc == nil
  end

  test "keeps a restored acc that is consistent with the restored window_tail" do
    # Sanity: a valid, count-matching acc from the same checkpoint state is preserved
    # so the NIF reuses the O(1) Welford state rather than recomputing every restore.
    series_key = "series-consistent-acc-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{} end)

    context = %{
      baseline: [],
      window_tail: [10.0, 11.0, 12.0],
      rolling_acc: %{count: 3, mean: 11.0, m2: 2.0},
      min_samples: 2,
      window_size: 3,
      n_sigma: 3.0,
      confirm_slots: 5,
      consecutive_anomalous: 0
    }

    checkpoint = %{
      version: 1,
      series_key: series_key,
      updates: [],
      verdicts: %{},
      base_context: context,
      context: context
    }

    Agent.update(checkpoint_agent, &Map.put(&1, series_key, checkpoint))

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.AgentCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      checkpoint_flush_interval_ms: 0,
      reasoner: __MODULE__.CompactStateReasoner,
      window_size: 3,
      min_samples: 2
    ]

    {:ok, pid} = start_owner(opts)
    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.checkpoint_restored?
    assert snapshot.context.window_tail == [10.0, 11.0, 12.0]
    assert snapshot.context.rolling_acc.count == 3
    assert_in_delta snapshot.context.rolling_acc.mean, 11.0, 0.0001
    assert_in_delta snapshot.context.rolling_acc.m2, 2.0, 0.0001
  end

  test "restores rolling_acc as nil when the checkpoint omits the acc for a window_tail" do
    # Fix(review): a checkpoint may carry a window_tail with no rolling_acc at all
    # (e.g. written by an older reasoner). The owner must NOT borrow base_context's
    # acc as a fallback; it sets rolling_acc to nil so the NIF recomputes.
    series_key = "series-missing-acc-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{} end)

    window_tail = [10.0, 11.0, 12.0]

    context = %{
      baseline: [],
      window_tail: window_tail,
      # rolling_acc intentionally omitted.
      min_samples: 2,
      window_size: 3,
      n_sigma: 3.0,
      confirm_slots: 5,
      consecutive_anomalous: 0
    }

    checkpoint = %{
      version: 1,
      series_key: series_key,
      updates: [],
      verdicts: %{},
      base_context: context,
      context: context
    }

    Agent.update(checkpoint_agent, &Map.put(&1, series_key, checkpoint))

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.AgentCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      checkpoint_flush_interval_ms: 0,
      reasoner: __MODULE__.CompactStateReasoner,
      window_size: 3,
      min_samples: 2
    ]

    {:ok, pid} = start_owner(opts)
    snapshot = ContextOwner.snapshot(pid)

    assert snapshot.checkpoint_restored?
    assert snapshot.context.window_tail == window_tail
    assert snapshot.context.rolling_acc == nil
    assert snapshot.base_context.rolling_acc == nil
  end

  test "checkpoint replay preserves anomalous verdict evidence after JSON restore" do
    series_key = "series-verdict-replay-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{} end)

    opts = [
      series_key: series_key,
      checkpoint_store: __MODULE__.JsonCheckpoint,
      checkpoint_opts: [agent: checkpoint_agent],
      checkpoint_flush_interval_ms: 0,
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

  test "checkpoint writes are coalesced behind an explicit flush" do
    series_key = "series-coalesced-checkpoint-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{checkpoints: %{}, saves: %{}} end)

    {:ok, pid} =
      start_owner(
        series_key: series_key,
        checkpoint_store: __MODULE__.CountingCheckpoint,
        checkpoint_opts: [agent: checkpoint_agent],
        checkpoint_flush_interval_ms: 60_000,
        min_samples: 2
      )

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e2", 2, 11.0))
    assert __MODULE__.CountingCheckpoint.save_count(checkpoint_agent, series_key) == 0

    assert :ok = ContextOwner.flush_checkpoint(pid)

    assert __MODULE__.CountingCheckpoint.save_count(checkpoint_agent, series_key) == 1

    checkpoint = __MODULE__.CountingCheckpoint.checkpoint(checkpoint_agent, series_key)
    assert Enum.map(checkpoint.updates, & &1.event_id) == ["e1", "e2"]
    assert checkpoint.context.baseline == []
    assert checkpoint.context.window_tail == [10.0, 11.0]
  end

  test "shutdown flushes a pending coalesced checkpoint" do
    series_key = "series-shutdown-checkpoint-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{checkpoints: %{}, saves: %{}} end)

    {:ok, pid} =
      start_owner(
        series_key: series_key,
        checkpoint_store: __MODULE__.CountingCheckpoint,
        checkpoint_opts: [agent: checkpoint_agent],
        checkpoint_flush_interval_ms: 60_000,
        min_samples: 2
      )

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e2", 2, 11.0))
    assert __MODULE__.CountingCheckpoint.save_count(checkpoint_agent, series_key) == 0

    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}

    assert __MODULE__.CountingCheckpoint.save_count(checkpoint_agent, series_key) == 1
    checkpoint = __MODULE__.CountingCheckpoint.checkpoint(checkpoint_agent, series_key)
    assert Enum.map(checkpoint.updates, & &1.event_id) == ["e1", "e2"]
  end

  test "registry name conflict steps down cleanly and flushes pending checkpoint" do
    series_key = "series-name-conflict-#{System.unique_integer([:positive])}"
    {:ok, checkpoint_agent} = Agent.start_link(fn -> %{checkpoints: %{}, saves: %{}} end)

    {:ok, pid} =
      start_owner(
        series_key: series_key,
        checkpoint_store: __MODULE__.CountingCheckpoint,
        checkpoint_opts: [agent: checkpoint_agent],
        checkpoint_flush_interval_ms: 60_000,
        min_samples: 2
      )

    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))
    assert {:ok, %{state: "clean"}} = ContextOwner.evaluate(pid, sample("e2", 2, 11.0))
    assert __MODULE__.CountingCheckpoint.save_count(checkpoint_agent, series_key) == 0

    ref = Process.monitor(pid)
    Process.unlink(pid)
    sender = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(sender, :kill) end)

    send(
      pid,
      {:EXIT, sender,
       {:name_conflict, {{:anomaly_context, series_key}, nil}, ServiceRadar.ProcessRegistry,
        self()}}
    )

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert __MODULE__.CountingCheckpoint.save_count(checkpoint_agent, series_key) == 1
  end

  test "context owners are transient so clean registry conflict exits are not restarted" do
    assert %{restart: :transient} = ContextOwner.child_spec(series_key: "series-1")
  end

  test "checkpoint revision conflict stops the owner" do
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    {:ok, pid} =
      start_owner(
        checkpoint_store: __MODULE__.ConflictCheckpoint,
        checkpoint_flush_interval_ms: 0
      )

    ref = Process.monitor(pid)

    assert {:error, :checkpoint_revision_conflict} =
             ContextOwner.evaluate(pid, sample("e1", 1, 10.0))

    assert_receive {:DOWN, ^ref, :process, ^pid, :checkpoint_revision_conflict}
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
    assert snapshot.base_context.baseline == []
    assert snapshot.base_context.window_tail == [8.0, 9.0]
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

  defmodule CompactStateReasoner do
    @moduledoc false

    def reason(context, sample) do
      tail =
        context
        |> Map.get(:window_tail, context.baseline)
        |> Kernel.++([sample.value])
        |> Enum.take(-context.window_size)

      {:ok,
       %{
         state: "clean",
         include_in_baseline: true,
         next_consecutive_anomalous: 0,
         next_window_tail: tail,
         next_rolling_acc: rolling_acc(tail)
       }}
    end

    defp rolling_acc([]), do: %{count: 0, mean: 0.0, m2: 0.0}

    defp rolling_acc(values) do
      count = length(values)
      mean = Enum.sum(values) / count
      m2 = values |> Enum.map(&((&1 - mean) * (&1 - mean))) |> Enum.sum()
      %{count: count, mean: mean, m2: m2}
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
        Map.get(context, :window_tail, context.baseline),
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

    def checkpoint(agent, series_key) do
      Agent.get(agent, &Map.fetch!(&1.checkpoints, series_key))
    end
  end

  defmodule ConflictCheckpoint do
    @moduledoc false
    def load(_series_key, _opts), do: {:ok, nil}
    def save(_series_key, _checkpoint, _opts), do: {:error, :checkpoint_revision_conflict}
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
          checkpoint_flush_interval_ms: 0,
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
