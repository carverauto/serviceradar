defmodule ServiceRadarWebNG.AlertActionsTransactionTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.NotificationAcknowledgement
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.AlertActions

  setup do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)
    actor = SystemActor.system(:alert_actions_transaction_test)

    alert =
      Alert
      |> Ash.Changeset.for_create(
        :trigger,
        %{
          title: "Web resolution transaction",
          description: "Regression fixture",
          severity: :critical,
          source_type: :service_check,
          source_id: "alert-actions-transaction-#{System.unique_integer([:positive])}"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, actor: actor, alert: alert, scope: scope}
  end

  test "resolve and its durable routing request commit together", %{
    actor: actor,
    alert: alert,
    scope: scope
  } do
    alert_id = alert.id

    assert {:error, _reason} =
             AlertActions.resolve(scope, alert_id, enqueue_routing: fn ^alert_id, :resolve -> {:error, :queue_down} end)

    assert {:ok, reloaded} = Alert.get_by_id(alert_id, actor: actor)
    assert reloaded.status == :pending
    assert acknowledgements(alert_id, actor) == []

    test_pid = self()

    assert {:ok, resolved} =
             AlertActions.resolve(scope, alert_id,
               enqueue_routing: fn ^alert_id, :resolve ->
                 send(test_pid, {:routing_enqueued, alert_id})
                 {:ok, :job}
               end
             )

    assert resolved.status == :resolved
    assert_received {:routing_enqueued, ^alert_id}
    assert [_acknowledgement] = acknowledgements(alert_id, actor)

    assert {:error, {:not_allowed, _message}} = AlertActions.resolve(scope, alert_id)
    refute_received {:routing_enqueued, _}
  end

  defp acknowledgements(alert_id, actor) do
    {:ok, rows} = NotificationAcknowledgement.list_for_alert(alert_id, actor: actor)
    rows
  end
end
