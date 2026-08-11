defmodule ServiceRadar.Notifications.ContinuationWorkerTest do
  @moduledoc """
  The delivery-keyed scheduler's routing of `Dispatcher.due/2`'s two lists.

  The property worth protecting is that the two lists go to **different**
  workers. `:retry` holds delivery ids and becomes a `DispatchWorker`; `:escalation`
  holds *alert* ids and becomes a `RoutingWorker` with `lifecycle_reason:
  :escalate`, because an escalation rung is a plan decision and `route/3` is the
  only path allowed to create a delivery row. Sending an alert id to the dispatch
  worker would look almost right and would try to deliver a row that does not
  exist; creating the row here instead would be a second origination path racing
  design D8's.

  Also asserted: one bad enqueue does not stop the rest of the tick, and `now` is
  captured once and passed down rather than being read again inside `due/2`.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.ContinuationWorker

  @now ~U[2026-08-09 12:00:00.000000Z]

  # Runs in the calling process, so the answer it should give is read from that
  # process's dictionary and the suite stays async.
  defmodule Dispatcher do
    @moduledoc false
    def due(now, opts) do
      send(self(), {:due, now, opts})
      Process.get(:due_result, %{retry: [], escalation: [], renotify: []})
    end
  end

  defp due(result), do: Process.put(:due_result, result)

  defp job, do: %Oban.Job{args: %{}}

  defp seams do
    test = self()

    [
      dispatcher: Dispatcher,
      enqueue_dispatch: fn delivery_id ->
        send(test, {:dispatch, delivery_id})
        {:ok, %Oban.Job{id: 1}}
      end,
      enqueue_routing: fn alert_id, reason ->
        send(test, {:routing, alert_id, reason})
        {:ok, %Oban.Job{id: 2}}
      end,
      send_renotify: fn alert_id, now ->
        send(test, {:renotify, alert_id, now})
        :ok
      end,
      now: @now
    ]
  end

  describe "queueing due work" do
    test "retry-due delivery ids become dispatch jobs" do
      due(%{retry: ["delivery-1", "delivery-2"], escalation: [], renotify: []})

      assert :ok = ContinuationWorker.sweep(job(), seams())

      assert_received {:dispatch, "delivery-1"}
      assert_received {:dispatch, "delivery-2"}
      refute_received {:routing, _alert_id, _reason}
    end

    test "escalation-due alert ids become routing jobs, not dispatch jobs" do
      # An alert id handed to the dispatch worker would try to deliver a row that
      # does not exist. The rung has to be planned first.
      due(%{retry: [], escalation: ["alert-1"], renotify: []})

      assert :ok = ContinuationWorker.sweep(job(), seams())

      assert_received {:routing, "alert-1", :escalate}
      refute_received {:dispatch, _id}
    end

    test "both lists are drained in one tick" do
      due(%{retry: ["delivery-1"], escalation: ["alert-1"], renotify: []})

      assert :ok = ContinuationWorker.sweep(job(), seams())

      assert_received {:dispatch, "delivery-1"}
      assert_received {:routing, "alert-1", :escalate}
    end

    test "an empty scan is a silent no-op" do
      due(%{retry: [], escalation: [], renotify: []})

      assert :ok = ContinuationWorker.sweep(job(), seams())

      refute_received {:dispatch, _id}
      refute_received {:routing, _alert_id, _reason}
    end

    test "renotify-due alerts run through the lifecycle callback" do
      due(%{retry: [], escalation: [], renotify: ["alert-1"]})

      assert :ok = ContinuationWorker.sweep(job(), seams())

      assert_received {:renotify, "alert-1", @now}
      refute_received {:dispatch, _delivery_id}
      refute_received {:routing, _alert_id, _reason}
    end
  end

  describe "the scan instant" do
    test "now is captured once and handed to due/2" do
      # The pure cores never read the clock; the impure layer captures `now` and
      # threads it down. A tick that let due/2 call DateTime.utc_now/0 itself
      # would make its two reads disagree about what is due.
      due(%{retry: [], escalation: [], renotify: []})

      assert :ok = ContinuationWorker.sweep(job(), seams())

      assert_received {:due, @now, _opts}
    end

    test "the collaborator seams are not leaked into due/2's options" do
      due(%{retry: [], escalation: [], renotify: []})

      assert :ok = ContinuationWorker.sweep(job(), seams())

      assert_received {:due, @now, opts}
      refute Keyword.has_key?(opts, :dispatcher)
      refute Keyword.has_key?(opts, :enqueue_dispatch)
      refute Keyword.has_key?(opts, :enqueue_routing)
      refute Keyword.has_key?(opts, :send_renotify)
      refute Keyword.has_key?(opts, :now)
    end

    test "a per-tick limit is always passed, so one incident cannot enqueue unbounded work" do
      due(%{retry: [], escalation: [], renotify: []})

      assert :ok = ContinuationWorker.sweep(job(), seams())

      assert_received {:due, @now, opts}
      assert is_integer(Keyword.fetch!(opts, :limit))
    end

    test "an explicit limit wins over the configured default" do
      due(%{retry: [], escalation: [], renotify: []})

      assert :ok = ContinuationWorker.sweep(job(), Keyword.put(seams(), :limit, 7))

      assert_received {:due, @now, opts}
      assert Keyword.fetch!(opts, :limit) == 7
    end
  end

  describe "failure isolation" do
    test "one failed enqueue does not stop the rest of the tick" do
      test = self()

      due(%{
        retry: ["delivery-bad", "delivery-good"],
        escalation: ["alert-1"],
        renotify: []
      })

      opts =
        Keyword.put(seams(), :enqueue_dispatch, fn
          "delivery-bad" ->
            {:error, :oban_unavailable}

          id ->
            send(test, {:dispatch, id})
            {:ok, %Oban.Job{id: 1}}
        end)

      assert :ok = ContinuationWorker.sweep(job(), opts)

      assert_received {:dispatch, "delivery-good"}
      assert_received {:routing, "alert-1", :escalate}
    end

    test "the tick always completes, because a failed scan is superseded a minute later" do
      due(%{retry: ["delivery-1"], escalation: [], renotify: []})

      opts = Keyword.put(seams(), :enqueue_dispatch, fn _id -> {:error, :boom} end)

      # Never {:error, _}: with max_attempts 1 that would only discard the job,
      # and re-running a stale scan is strictly worse than re-scanning.
      assert :ok = ContinuationWorker.sweep(job(), opts)
    end
  end

  describe "oban options" do
    test "the tick is a singleton on the notifications queue with one attempt" do
      changes = ContinuationWorker.new(%{}).changes

      assert changes.queue == "notifications"
      assert changes.max_attempts == 1
      assert %{period: :infinity, states: states} = changes.unique
      assert :executing in states
    end
  end

  describe "config/0" do
    test "defaults to a bounded per-list limit" do
      assert %{limit: limit, stall_seconds: nil} = ContinuationWorker.config()
      assert is_integer(limit) and limit > 0
    end
  end
end
