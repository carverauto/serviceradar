defmodule ServiceRadar.Monitoring.AlertSendNotificationTriggerTest do
  @moduledoc """
  The wiring between the AshOban `:send_notifications` trigger, the read action
  that feeds it, and the update action it runs.

  All four pieces are declarative, and a mistake in any of them is silent: a
  trigger that names a read action which no longer exists, a read action whose
  filter can never match, or an update action that logs instead of enqueueing
  all produce a system that looks healthy and pages nobody. None of that needs a
  database to check.
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.Changes.EnqueueRoutingRequest
  alias ServiceRadar.Monitoring.Changes.RecordNotificationSent

  describe "the :send_notifications trigger" do
    test "resolves, and runs :send_notification over :needs_notification" do
      trigger = AshOban.Info.oban_trigger(Alert, :send_notifications)

      assert trigger.state == :active
      assert trigger.queue == :notifications
      assert trigger.read_action == :needs_notification
      assert trigger.action == :send_notification
      assert trigger.worker == Alert.SendNotificationsWorker
      assert trigger.scheduler == Alert.SendNotificationsScheduler
    end

    test "names actions that exist" do
      assert %{type: :read} = Info.action(Alert, :needs_notification)
      assert %{type: :update} = Info.action(Alert, :send_notification)
    end
  end

  describe ":send_notification" do
    test "enqueues a :fire routing request and records the notification" do
      assert changes(:send_notification) == [
               {RecordNotificationSent, []},
               {EnqueueRoutingRequest, [lifecycle_reason: :fire]}
             ]
    end

    test "is atomic" do
      # The counter it increments is the flag `read :needs_notification` selects
      # on, so a lost update re-arms the first-notification scan. It used to
      # carry `require_atomic? false` and a read-then-write increment in Elixir.
      assert Info.action(Alert, :send_notification).require_atomic?
    end
  end

  describe ":record_notification" do
    test "records the notification and enqueues nothing" do
      # The renotify caller emits its own routing request; enqueueing here as
      # well would page twice for one decision.
      assert changes(:record_notification) == [{RecordNotificationSent, []}]
    end

    test "is atomic" do
      assert Info.action(Alert, :record_notification).require_atomic?
    end
  end

  defp changes(action) do
    Alert
    |> Info.action(action)
    |> Map.fetch!(:changes)
    |> Enum.map(fn %{change: {module, opts}} -> {module, opts} end)
  end
end
