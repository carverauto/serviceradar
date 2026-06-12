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

  test "late samples outside a full window are dropped explicitly" do
    {:ok, pid} = start_owner(max_events: 2)

    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("e2", 2, 20.0))
    assert {:ok, _verdict} = ContextOwner.evaluate(pid, sample("e3", 3, 30.0))

    assert {:drop, :outside_window} = ContextOwner.evaluate(pid, sample("e1", 1, 10.0))

    snapshot = ContextOwner.snapshot(pid)
    assert snapshot.event_ids == ["e2", "e3"]
    assert snapshot.context.baseline == [20.0, 30.0]
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

  defp start_owner(opts \\ []) do
    ContextOwner.start_link(
      Keyword.merge(
        [
          series_key: "series-#{System.unique_integer([:positive])}",
          name: nil,
          reasoner: __MODULE__.CleanReasoner
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
