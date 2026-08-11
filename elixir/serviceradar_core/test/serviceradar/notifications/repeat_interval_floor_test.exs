defmodule ServiceRadar.Notifications.RepeatIntervalFloorTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Repo

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "the largest enabled rule interval is the strictest save-time floor" do
    actor = SystemActor.system(:notification_repeat_floor_test)

    Ecto.Adapters.SQL.query!(Repo, "UPDATE platform.stateful_alert_rules SET enabled = false", [])

    create_rule!(actor, 900)
    create_rule!(actor, 3600)

    assert {:error, error} = create_policy(actor, 1800)
    assert Exception.message(error) =~ "must be at least 3600 seconds"

    assert {:ok, policy} = create_policy(actor, 3600)
    assert policy.repeat_interval_seconds == 3600
  end

  defp create_rule!(actor, renotify_seconds) do
    StatefulAlertRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "notification-floor-#{renotify_seconds}-#{System.unique_integer([:positive])}",
        renotify_seconds: renotify_seconds
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_policy(actor, repeat_interval_seconds) do
    NotificationEscalationPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "floor-policy-#{repeat_interval_seconds}-#{System.unique_integer([:positive])}",
        repeat_count: 1,
        repeat_interval_seconds: repeat_interval_seconds
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end
end
