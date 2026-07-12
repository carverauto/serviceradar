defmodule ServiceRadar.Observability.PluginStateTransactionTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  test "notification-aware state upserts do not publish effects from a rolled-back transaction" do
    {_payload, status, observed_at} = plugin_result_fixture()
    :ok = ServiceStatePubSub.subscribe()

    attrs = %{
      agent_id: status.agent_id,
      gateway_id: status.gateway_id,
      partition: status.partition,
      service_type: status.service_type,
      service_name: status.service_name,
      available: false,
      message: "must roll back",
      timestamp: observed_at
    }

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert {:ok, notifications, side_effects} =
                        ServiceStateRegistry.upsert_from_status_strict_with_notifications(attrs)

               assert is_list(notifications)
               assert side_effects != []
               refute_receive {:service_state_updated, _state}
               Repo.rollback(:forced_rollback)
             end)

    refute_receive {:service_state_updated, _state}, 50
    assert [] = current_state_rows(status)
  end
end
