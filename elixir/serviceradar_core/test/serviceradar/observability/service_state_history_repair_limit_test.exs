defmodule ServiceRadar.Observability.ServiceStateHistoryRepairLimitTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  test "limit caps total repaired identities independently of batch size" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {first_payload, first_status, _observed_at} = plugin_result_fixture()
    {second_payload, second_status, _observed_at} = plugin_result_fixture()

    assert :ok = PluginResultIngestor.ingest(first_payload, first_status)
    assert :ok = PluginResultIngestor.ingest(second_payload, second_status)

    Repo.query!(
      "DELETE FROM platform.service_state WHERE agent_id = ANY($1::text[])",
      [[first_status.agent_id, second_status.agent_id]]
    )

    assert {:ok, _count} =
             ServiceStateRegistry.repair_plugin_states_from_history(
               interval: "1 day",
               batch_size: 10,
               limit: 1
             )

    repaired_rows =
      length(current_state_rows(first_status)) + length(current_state_rows(second_status))

    assert repaired_rows == 1

    assert {:ok, _count} =
             ServiceStateRegistry.repair_plugin_states_from_history(
               interval: "1 day",
               batch_size: 1
             )

    assert length(current_state_rows(first_status)) == 1
    assert length(current_state_rows(second_status)) == 1
  end

  test "a finite limit spans keyset pages without exceeding the cap" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    fixtures = for _ <- 1..3, do: plugin_result_fixture()

    Enum.each(fixtures, fn {payload, status, _observed_at} ->
      assert :ok = PluginResultIngestor.ingest(payload, status)
    end)

    statuses = Enum.map(fixtures, fn {_payload, status, _observed_at} -> status end)

    Repo.query!(
      "DELETE FROM platform.service_state WHERE agent_id = ANY($1::text[])",
      [Enum.map(statuses, & &1.agent_id)]
    )

    assert {:ok, _count} =
             ServiceStateRegistry.repair_plugin_states_from_history(
               interval: "1 day",
               batch_size: 1,
               limit: 2
             )

    assert Enum.count(statuses, &(current_state_rows(&1) != [])) == 2
  end
end
