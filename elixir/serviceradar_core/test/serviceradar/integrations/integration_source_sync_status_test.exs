defmodule ServiceRadar.Integrations.IntegrationSourceSyncStatusTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: "system", email: "system@serviceradar", role: :admin}
    {:ok, actor: actor}
  end

  test "sync_success records second-precision last_sync_at", %{actor: actor} do
    source = create_source!(actor, name: unique_name("sync-success"))
    {:ok, running} = update_with_action(source, :sync_start, %{device_count: 10}, actor)

    assert {:ok, success} =
             update_with_action(
               running,
               :sync_success,
               %{result: :success, device_count: 10},
               actor
             )

    assert success.sync_status == :success
    assert success.last_sync_result == :success
    assert success.last_device_count == 10
    assert success.last_sync_at.microsecond == {0, 0}
  end

  test "sync_failed records second-precision last_sync_at", %{actor: actor} do
    source = create_source!(actor, name: unique_name("sync-failed"))
    {:ok, running} = update_with_action(source, :sync_start, %{device_count: 0}, actor)

    assert {:ok, failed} =
             update_with_action(
               running,
               :sync_failed,
               %{
                 result: :failed,
                 device_count: 0,
                 error_message: "decode failed"
               },
               actor
             )

    assert failed.sync_status == :failed
    assert failed.last_sync_result == :failed
    assert failed.last_error_message == "decode failed"
    assert failed.last_sync_at.microsecond == {0, 0}
  end

  test "sync_start clears stale failure message from prior run", %{actor: actor} do
    source = create_source!(actor, name: unique_name("sync-start-clears-error"))
    {:ok, running} = update_with_action(source, :sync_start, %{device_count: 0}, actor)

    {:ok, failed} =
      update_with_action(
        running,
        :sync_failed,
        %{
          result: :failed,
          device_count: 0,
          error_message: "old timestamp precision error"
        },
        actor
      )

    assert failed.last_error_message == "old timestamp precision error"

    assert {:ok, rerunning} =
             update_with_action(failed, :sync_start, %{device_count: 10}, actor)

    assert rerunning.sync_status == :running
    assert rerunning.last_error_message == nil
  end

  defp create_source!(actor, attrs) do
    endpoint = "https://example.invalid/#{System.unique_integer([:positive])}"
    agent = create_connected_agent!(actor)

    defaults = %{
      name: unique_name("armis-source"),
      source_type: :armis,
      endpoint: endpoint,
      agent_id: agent.uid,
      credentials: %{token: "secret"}
    }

    IntegrationSource
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, Map.new(attrs)), actor: actor)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, source} -> source
      {:error, reason} -> raise "failed to create integration source: #{inspect(reason)}"
    end
  end

  defp create_connected_agent!(actor) do
    uid = unique_name("agent")

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp update_with_action(record, action, params, actor) do
    record
    |> Ash.Changeset.for_update(action, params, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
