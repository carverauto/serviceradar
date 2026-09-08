defmodule ServiceRadar.Notifications.DispatchScheduleTest do
  @moduledoc """
  The cron entries the notification platform must run in production.

  This suite exists for the same reason
  `ServiceRadar.Observability.ProductionScheduleTest` does: an entry that
  silently drops out of the crontab does not fail anything. The platform keeps
  routing and keeps sending first notifications, and only retry, escalation, and
  silence expiry stop - which looks exactly like "nothing went wrong" until
  somebody is not paged a second time.

  It also pins the two entries that must NOT be here. `RoutingWorker` and
  `DispatchWorker` are event-driven: routing is enqueued by the alert lifecycle
  (design D8 reserves originating a first notification for it) and by the
  continuation sweeper for a due rung; dispatch is enqueued by routing. A cron
  entry for either would be a third origination path racing the other two.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.ContinuationWorker
  alias ServiceRadar.Notifications.DeliveryRetentionWorker
  alias ServiceRadar.Notifications.DispatchSchedule
  alias ServiceRadar.Notifications.DispatchWorker
  alias ServiceRadar.Notifications.ReceiptWorker
  alias ServiceRadar.Notifications.RoutingWorker
  alias ServiceRadar.Notifications.SilenceExpiryWorker

  # A System.get_env/2-shaped fetcher over a plain map, so the env gating is
  # testable without mutating the process environment.
  defp fetch(env), do: fn name, default -> Map.get(env, name, default) end

  defp by_worker(entries) do
    Map.new(entries, fn
      {cron, worker} -> {worker, {cron, []}}
      {cron, worker, opts} -> {worker, {cron, opts}}
    end)
  end

  describe "cron_entries/1" do
    test "every scheduled worker is present by default" do
      workers = %{} |> fetch() |> DispatchSchedule.cron_entries() |> by_worker() |> Map.keys()

      assert ContinuationWorker in workers
      assert ReceiptWorker in workers
      assert SilenceExpiryWorker in workers
      assert DeliveryRetentionWorker in workers
    end

    test "the event-driven workers are deliberately not scheduled" do
      workers = %{} |> fetch() |> DispatchSchedule.cron_entries() |> by_worker() |> Map.keys()

      refute RoutingWorker in workers
      refute DispatchWorker in workers
    end

    test "continuation and silence expiry run every minute on the notifications queue" do
      entries = %{} |> fetch() |> DispatchSchedule.cron_entries() |> by_worker()

      assert {"* * * * *", opts} = entries[ContinuationWorker]
      assert opts[:queue] == :notifications

      assert {"* * * * *", silence_opts} = entries[SilenceExpiryWorker]
      assert silence_opts[:queue] == :notifications
    end

    test "delivery retention runs daily on maintenance, off the notifications queue" do
      entries = %{} |> fetch() |> DispatchSchedule.cron_entries() |> by_worker()

      assert {cron, opts} = entries[DeliveryRetentionWorker]
      # Daily rather than per-minute, and not on the queue the delivery worker
      # shares five slots with.
      assert cron =~ ~r/^\d+ \d+ \* \* \*$/
      assert opts[:queue] == :maintenance
    end

    test "each cron expression is overridable" do
      env = %{
        "SERVICERADAR_NOTIFICATION_CONTINUATION_CRON" => "*/2 * * * *",
        "SERVICERADAR_NOTIFICATION_RECEIPT_SWEEP_CRON" => "*/4 * * * *",
        "SERVICERADAR_NOTIFICATION_SILENCE_SWEEP_CRON" => "*/3 * * * *",
        "SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_CRON" => "5 2 * * *"
      }

      entries = env |> fetch() |> DispatchSchedule.cron_entries() |> by_worker()

      assert {"*/2 * * * *", _} = entries[ContinuationWorker]
      assert {"*/4 * * * *", _} = entries[ReceiptWorker]
      assert {"*/3 * * * *", _} = entries[SilenceExpiryWorker]
      assert {"5 2 * * *", _} = entries[DeliveryRetentionWorker]
    end

    test "each entry is individually disablable" do
      env = %{
        "SERVICERADAR_NOTIFICATION_CONTINUATION_ENABLED" => "false",
        "SERVICERADAR_NOTIFICATION_RECEIPT_SWEEP_ENABLED" => "no",
        "SERVICERADAR_NOTIFICATION_SILENCE_SWEEP_ENABLED" => "0",
        "SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_ENABLED" => "off"
      }

      assert env |> fetch() |> DispatchSchedule.cron_entries() == []
    end

    test "disabling continuation leaves the others scheduled" do
      env = %{"SERVICERADAR_NOTIFICATION_CONTINUATION_ENABLED" => "false"}

      workers = env |> fetch() |> DispatchSchedule.cron_entries() |> by_worker() |> Map.keys()

      refute ContinuationWorker in workers
      assert ReceiptWorker in workers
      assert SilenceExpiryWorker in workers
      assert DeliveryRetentionWorker in workers
    end
  end

  describe "worker configuration" do
    test "nothing is configured when the operator set nothing" do
      # The worker modules' own defaults stay authoritative when unset.
      assert DispatchSchedule.continuation_worker_config(fetch(%{})) == []
      assert DispatchSchedule.receipt_worker_config(fetch(%{})) == []
      assert DispatchSchedule.silence_expiry_worker_config(fetch(%{})) == []
      assert DispatchSchedule.delivery_retention_worker_config(fetch(%{})) == []
    end

    test "the delivery retention window is its own knob" do
      env = %{"SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_DAYS" => "90"}

      assert DispatchSchedule.delivery_retention_worker_config(fetch(env)) == [
               retention_days: 90
             ]
    end

    test "continuation bounds are settable" do
      env = %{
        "SERVICERADAR_NOTIFICATION_CONTINUATION_LIMIT" => "250",
        "SERVICERADAR_NOTIFICATION_DISPATCH_STALL_SECONDS" => "600"
      }

      assert DispatchSchedule.continuation_worker_config(fetch(env)) == [
               limit: 250,
               stall_seconds: 600
             ]
    end

    test "the receipt sweep bound is settable" do
      env = %{"SERVICERADAR_NOTIFICATION_RECEIPT_LIMIT" => "120"}

      assert DispatchSchedule.receipt_worker_config(fetch(env)) == [limit: 120]
    end

    test "a blank value counts as unset" do
      env = %{"SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_DAYS" => ""}

      assert DispatchSchedule.delivery_retention_worker_config(fetch(env)) == []
    end

    test "a malformed value fails fast with the variable named" do
      # Naming the variable is the point: this is evaluated at release boot, and
      # an unattributable ArgumentError there is a very expensive way to learn
      # that somebody wrote "30d".
      env = %{"SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_DAYS" => "30d"}

      assert_raise ArgumentError, ~r/SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_DAYS/, fn ->
        DispatchSchedule.delivery_retention_worker_config(fetch(env))
      end
    end

    test "a non-positive window is rejected rather than deleting everything" do
      env = %{"SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_DAYS" => "0"}

      assert_raise ArgumentError, fn ->
        DispatchSchedule.delivery_retention_worker_config(fetch(env))
      end
    end
  end
end
