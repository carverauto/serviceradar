defmodule ServiceRadar.Notifications.ReceiptWorkerTest do
  @moduledoc """
  The receipt sweep's contract with `Dispatcher.reconcile/2` (tasks 3.4.4,
  3.4.5).

  Two properties are worth protecting and both are invisible when they break.

  The settled list is already written and must NOT be re-queued: enqueuing a
  delivery the reconciler just drove to `:sent` would hand it a second attempt
  the operator never configured.

  The drain list must be enqueued with `replace: [scheduled: [:scheduled_at]]`.
  A drained delivery already has a snoozed `DispatchWorker` job, and
  `DispatchWorker`'s unique key spans the incomplete states - so a plain enqueue
  is a conflict that returns `{:ok, job}` and changes nothing at all. The drain
  would look like it worked and the delivery would keep waiting out a backoff
  for an agent that is already back.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.ReceiptWorker

  @now ~U[2026-08-10 12:00:00.000000Z]

  defmodule Dispatcher do
    @moduledoc false
    def reconcile(now, opts) do
      send(self(), {:reconcile, now, opts})
      Process.get(:reconcile_result, %{settled: [], drain: []})
    end
  end

  defp job, do: %Oban.Job{args: %{}}

  defp sweep(opts) do
    ReceiptWorker.sweep(
      job(),
      Keyword.merge([dispatcher: Dispatcher, now: @now, enqueue_drain: &record_drain/1], opts)
    )
  end

  defp record_drain(delivery_id) do
    send(self(), {:drained, delivery_id})
    Process.get(:drain_result, {:ok, %Oban.Job{}})
  end

  describe "sweep/2" do
    test "passes the captured instant and the configured bound to reconcile/2" do
      assert :ok = sweep([])

      assert_received {:reconcile, @now, opts}
      assert opts[:limit] == 500
    end

    test "an explicit limit is not overridden by the configured default" do
      assert :ok = sweep(limit: 10)

      assert_received {:reconcile, @now, opts}
      assert opts[:limit] == 10
    end

    test "settled deliveries are not re-queued" do
      Process.put(:reconcile_result, %{settled: ["settled-1", "settled-2"], drain: []})

      assert :ok = sweep([])

      refute_received {:drained, _id}
    end

    test "drained deliveries are re-queued" do
      Process.put(:reconcile_result, %{settled: [], drain: ["drain-1", "drain-2"]})

      assert :ok = sweep([])

      assert_received {:drained, "drain-1"}
      assert_received {:drained, "drain-2"}
    end

    test "one failed re-queue does not stop the rest of the tick" do
      Process.put(:reconcile_result, %{settled: [], drain: ["drain-1", "drain-2"]})
      Process.put(:drain_result, {:error, :oban_unavailable})

      assert :ok = sweep([])

      assert_received {:drained, "drain-1"}
      assert_received {:drained, "drain-2"}
    end
  end

  describe "the Oban contract" do
    test "one execution, on the notifications queue, unique while incomplete" do
      # Retry is owned by the delivery row, never by Oban's attempt counter, and
      # a failed scan is superseded by the next tick against fresher data.
      assert ReceiptWorker.__opts__()[:max_attempts] == 1
      assert ReceiptWorker.__opts__()[:queue] == :notifications
      assert ReceiptWorker.__opts__()[:unique][:states] == :incomplete
    end

    test "the drain enqueue replaces the scheduled_at of an existing job" do
      # Read from the source rather than reimplemented here: this is the one
      # option that makes the drain do anything, and a test that restated it
      # would pass while the code lost it.
      source =
        "../../../lib/serviceradar/notifications/receipt_worker.ex"
        |> Path.expand(__DIR__)
        |> File.read!()

      assert source =~ "replace: [scheduled: [:scheduled_at]]"
    end
  end
end
