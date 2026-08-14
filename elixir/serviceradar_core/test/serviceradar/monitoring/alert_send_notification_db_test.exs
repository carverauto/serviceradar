defmodule ServiceRadar.Monitoring.AlertSendNotificationDbTest do
  @moduledoc """
  `Alert.:send_notification` end to end: the AshOban first-notification safety
  net enqueues a routing request, records the notification atomically, and by
  doing so removes the alert from the scan that produced it.

  Needs a database because the point of the test is the atomic UPDATE and the
  `oban_jobs` row it commits alongside.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @routing_worker "ServiceRadar.Notifications.RoutingWorker"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:alert_send_notification_test)}
  end

  test "enqueues one :fire routing request and records the notification", %{actor: actor} do
    alert = trigger_alert!(actor)

    assert alert.notification_count == 0
    assert alert.id in needs_notification_ids(actor)

    assert {:ok, notified} = send_notification(alert, actor)

    assert notified.notification_count == 1
    assert notified.last_notification_at

    assert [job] = routing_jobs(alert.id)
    assert job["args"]["lifecycle_reason"] == "fire"
    assert job["queue"] == "notifications"

    # The counter is the flag: having notified once, the first-notification scan
    # must not hand this alert back on the next tick.
    refute alert.id in needs_notification_ids(actor)
  end

  test "running it twice does not produce a second routing request", %{actor: actor} do
    # Oban's `unique` on the routing request collapses the repeat, and
    # `Dispatcher.route/3` would have collapsed it again. Both matter: the job
    # is idempotent, and so is the work it does.
    alert = trigger_alert!(actor)

    assert {:ok, notified} = send_notification(alert, actor)
    assert {:ok, twice} = send_notification(notified, actor)

    assert twice.notification_count == 2
    assert [_one] = routing_jobs(alert.id)
  end

  test "a snoozed alert is not offered to the trigger", %{actor: actor} do
    alert = trigger_alert!(actor)

    {:ok, snoozed} =
      alert
      |> Ash.Changeset.for_update(
        :snooze,
        %{snooze_until: DateTime.add(DateTime.utc_now(), 3600, :second)},
        actor: actor
      )
      |> Ash.update()

    refute snoozed.id in needs_notification_ids(actor)
  end

  defp trigger_alert!(actor) do
    {:ok, alert} =
      Alert
      |> Ash.Changeset.for_create(
        :trigger,
        %{
          title: "send-notification-wiring-#{System.unique_integer([:positive])}",
          description: "first notification wiring",
          severity: :critical,
          source_type: :system
        },
        actor: actor
      )
      |> Ash.create()

    alert
  end

  defp send_notification(alert, actor) do
    alert
    |> Ash.Changeset.for_update(:send_notification, %{}, actor: actor)
    |> Ash.update()
  end

  defp needs_notification_ids(actor) do
    {:ok, alerts} =
      Alert
      |> Ash.Query.for_read(:needs_notification, %{}, actor: actor)
      |> Ash.Query.page(limit: 200)
      |> Ash.read()

    Enum.map(alerts.results, & &1.id)
  end

  defp routing_jobs(alert_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT queue, args
        FROM platform.oban_jobs
        WHERE worker = $1 AND args->>'alert_id' = $2
        ORDER BY id
        """,
        [@routing_worker, alert_id]
      )

    Enum.map(rows, fn [queue, args] -> %{"queue" => queue, "args" => args} end)
  end
end
