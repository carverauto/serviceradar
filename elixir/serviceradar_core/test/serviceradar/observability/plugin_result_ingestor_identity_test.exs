defmodule ServiceRadar.Observability.PluginResultIngestorIdentityTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  # These tests hold a real advisory lock in one transaction while other
  # processes ingest. Shared sandbox is one connection, so the waiters
  # time out in the checkout queue instead of blocking on the lock.
  @moduletag sandbox: :unboxed

  test "concurrent identities retain distinct reported history rows" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, first_status, observed_at} = plugin_result_fixture()

    second_status = %{
      first_status
      | agent_id: "#{first_status.agent_id}-concurrent",
        partition: "concurrent-partition",
        service_type: "plugin-concurrent"
    }

    on_exit(fn -> cleanup_identity_rows([first_status, second_status]) end)

    tasks =
      for status <- [first_status, second_status] do
        Task.async(fn -> PluginResultIngestor.ingest(payload, status) end)
      end

    assert [:ok, :ok] = Enum.map(tasks, &Task.await(&1, 5_000))

    assert [[first_reported_at, true, "edge plugin completed", first_details]] =
             history_rows(first_status)

    assert [[second_reported_at, true, "edge plugin completed", second_details]] =
             history_rows(second_status)

    assert [first_reported_at, second_reported_at] |> MapSet.new() |> MapSet.size() == 2

    assert first_reported_at ==
             assert_reported_event_block(
               [first_reported_at, true, "edge plugin completed", first_details],
               observed_at
             )

    assert second_reported_at ==
             assert_reported_event_block(
               [second_reported_at, true, "edge plugin completed", second_details],
               observed_at
             )

    for details <- [first_details, second_details] do
      assert %{"_serviceradar_plugin_result" => %{"kind" => "reported"}} =
               Jason.decode!(details)
    end

    assert [[true, _, _]] = current_state_rows(first_status)
    assert [[true, _, _]] = current_state_rows(second_status)
  end

  test "cross-gateway copies of one observation serialize one active logical state" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, first_status, observed_at} = plugin_result_fixture()
    second_status = %{first_status | gateway_id: "#{first_status.gateway_id}-alternate"}
    on_exit(fn -> cleanup_identity_rows([first_status, second_status]) end)

    observation_lock_identity =
      Jason.encode!([
        "plugin-result-observation",
        first_status.agent_id,
        first_status.partition,
        first_status.service_type,
        first_status.service_name,
        DateTime.to_iso8601(observed_at)
      ])

    parent = self()

    lock_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            observation_lock_identity
          ])

          send(parent, :cross_gateway_observation_lock_held)

          receive do
            :release_cross_gateway_observation_lock -> :ok
          after
            5_000 -> raise "timed out waiting to release cross-gateway observation lock"
          end
        end)
      end)

    assert_receive :cross_gateway_observation_lock_held, 5_000

    tasks =
      for status <- [first_status, second_status] do
        Task.async(fn ->
          result = PluginResultIngestor.ingest(payload, status)
          send(parent, {:cross_gateway_ingest_done, status.gateway_id})
          result
        end)
      end

    refute_receive {:cross_gateway_ingest_done, _gateway_id}, 250
    send(lock_holder.pid, :release_cross_gateway_observation_lock)
    assert {:ok, :ok} = Task.await(lock_holder, 5_000)
    assert [:ok, :ok] = Enum.map(tasks, &Task.await(&1, 5_000))

    for status <- [first_status, second_status] do
      assert [[reported_at, true, "edge plugin completed", details] = reported_row] =
               history_rows(status)

      assert reported_at == assert_reported_event_block(reported_row, observed_at)

      assert %{"_serviceradar_plugin_result" => %{"kind" => "reported"}} =
               Jason.decode!(details)
    end

    logical_states = logical_current_state_rows(first_status)
    assert length(logical_states) == 2
    assert Enum.count(logical_states, fn [_gateway_id, state] -> state == "active" end) == 1

    assert MapSet.new(logical_states, fn [gateway_id, _state] -> gateway_id end) ==
             MapSet.new([first_status.gateway_id, second_status.gateway_id])
  end

  defp cleanup_identity_rows(statuses) do
    agent_ids = statuses |> Enum.map(& &1.agent_id) |> Enum.uniq()
    gateway_ids = statuses |> Enum.map(& &1.gateway_id) |> Enum.uniq()

    Enum.each(agent_ids, fn agent_id ->
      Repo.query!("DELETE FROM platform.service_state WHERE agent_id = $1", [agent_id])
      Repo.query!("DELETE FROM platform.service_status WHERE agent_id = $1", [agent_id])
      Repo.query!("DELETE FROM platform.plugin_assignments WHERE agent_uid = $1", [agent_id])
      Repo.query!("DELETE FROM platform.ocsf_agents WHERE uid = $1", [agent_id])
    end)

    Enum.each(gateway_ids, fn gateway_id ->
      Repo.query!("DELETE FROM platform.gateways WHERE gateway_id = $1", [gateway_id])
    end)
  end
end
