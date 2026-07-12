defmodule ServiceRadar.Observability.PluginResultAssignmentLifecycleRaceTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState

  @moduletag sandbox: :unboxed
  @moduletag timeout: 30_000

  setup do
    suffix = System.unique_integer([:positive])
    plugin_id = "lifecycle-race-plugin-#{suffix}"

    status = %{
      source: "plugin-result",
      agent_id: "lifecycle-race-agent-#{suffix}",
      gateway_id: "lifecycle-race-gateway-#{suffix}",
      partition: "default",
      service_type: "plugin",
      service_name: "lifecycle-race-service-#{suffix}"
    }

    on_exit(fn -> cleanup_fixture(status, plugin_id) end)

    create_agent(status.agent_id, status.gateway_id)

    old_package =
      create_repair_package!(status.service_name,
        plugin_id: plugin_id,
        version: "1.0.0"
      )

    new_package =
      create_repair_package!(status.service_name,
        plugin_id: plugin_id,
        version: "2.0.0",
        create_plugin?: false
      )

    old_assignment =
      create_repair_assignment_for_package!(status, old_package, enabled: false)

    observed_at =
      DateTime.utc_now()
      |> DateTime.add(-30, :second)
      |> DateTime.truncate(:microsecond)

    seed_service_state(status, observed_at,
      available: true,
      message: "last real plugin result",
      state: "active"
    )

    real_details = %{
      "labels" => %{"plugin_id" => plugin_id},
      "result_kind" => "real"
    }

    Repo.query!(
      """
      UPDATE platform.service_state
      SET details = $1
      WHERE agent_id = $2
        AND gateway_id = $3
        AND partition = $4
        AND service_type = $5
        AND service_name = $6
      """,
      [
        Jason.encode!(real_details),
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    )

    {:ok,
     status: status,
     plugin_id: plugin_id,
     old_assignment: old_assignment,
     new_package: new_package,
     observed_at: observed_at,
     real_details: real_details}
  end

  test "deactivation rechecks a replacement assignment after acquiring the identity lock",
       context do
    parent = self()
    identity = context.status

    lock_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert :ok = PluginState.acquire_lock(identity)
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:lifecycle_identity_lock_held, backend_pid})

          receive do
            :release_lifecycle_identity_lock -> :ok
          after
            5_000 -> raise "timed out waiting to release lifecycle identity lock"
          end
        end)
      end)

    assert_receive {:lifecycle_identity_lock_held, lock_holder_backend_pid}, 5_000

    deactivation =
      Task.async(fn ->
        ServiceStateRegistry.deactivate_for_assignment(context.old_assignment)
      end)

    assert :ok = wait_until_blocked_by(lock_holder_backend_pid)

    _replacement =
      create_repair_assignment_for_package!(context.status, context.new_package)

    send(lock_holder.pid, :release_lifecycle_identity_lock)

    assert {:ok, :ok} = Task.await(lock_holder, 5_000)
    assert :ok = Task.await(deactivation, 5_000)

    assert [[true, "last real plugin result", context.observed_at, "active"]] ==
             current_state_rows_with_state(context.status)
  end

  test "a replacement assignment reactivates the real snapshot after deactivation wins the lock",
       context do
    parent = self()
    :ok = ServiceStatePubSub.subscribe()

    deactivation =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert :ok =
                   ServiceStateRegistry.deactivate_for_assignment(context.old_assignment)

          send(parent, :lifecycle_deactivation_prepared)

          receive do
            :commit_lifecycle_deactivation -> :ok
          after
            5_000 -> raise "timed out waiting to commit lifecycle deactivation"
          end
        end)
      end)

    assert_receive :lifecycle_deactivation_prepared, 5_000

    replacement =
      create_repair_assignment_for_package!(context.status, context.new_package)

    reactivation =
      Task.async(fn ->
        result = ServiceStateRegistry.upsert_for_assignment(replacement)
        send(parent, {:lifecycle_reactivation_finished, result})
        result
      end)

    refute_receive {:lifecycle_reactivation_finished, _result}, 200
    send(deactivation.pid, :commit_lifecycle_deactivation)

    assert {:ok, :ok} = Task.await(deactivation, 5_000)
    assert :ok = Task.await(reactivation, 5_000)
    assert_receive {:lifecycle_reactivation_finished, :ok}

    assert [[true, "last real plugin result", context.observed_at, "active"]] ==
             current_state_rows_with_state(context.status)

    assert Jason.decode!(current_state_details(context.status)) == context.real_details
    assert_receive_active_real_snapshot(context.status)
  end

  defp assert_receive_active_real_snapshot(status) do
    receive do
      {:service_state_updated,
       %{
         agent_id: agent_id,
         service_name: service_name,
         message: "last real plugin result",
         state: "active"
       }}
      when agent_id == status.agent_id and service_name == status.service_name ->
        :ok

      {:service_state_updated, _other_state} ->
        assert_receive_active_real_snapshot(status)
    after
      5_000 -> flunk("expected an active real-snapshot broadcast")
    end
  end

  defp wait_until_blocked_by(
         blocking_backend_pid,
         deadline \\ System.monotonic_time(:millisecond) + 5_000
       ) do
    blocked? =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_stat_activity
          WHERE $1 = ANY(pg_blocking_pids(pid))
        )
        """,
        [blocking_backend_pid]
      ).rows
      |> List.first()
      |> List.first()

    cond do
      blocked? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :advisory_waiter_timeout}

      true ->
        Process.sleep(20)
        wait_until_blocked_by(blocking_backend_pid, deadline)
    end
  end

  defp cleanup_fixture(status, plugin_id) do
    Repo.query!("DELETE FROM platform.service_state WHERE agent_id = $1", [status.agent_id])
    Repo.query!("DELETE FROM platform.service_status WHERE agent_id = $1", [status.agent_id])
    Repo.query!("DELETE FROM platform.plugin_assignments WHERE agent_uid = $1", [status.agent_id])
    Repo.query!("DELETE FROM platform.plugin_packages WHERE plugin_id = $1", [plugin_id])
    Repo.query!("DELETE FROM platform.plugins WHERE plugin_id = $1", [plugin_id])
    Repo.query!("DELETE FROM platform.ocsf_agents WHERE uid = $1", [status.agent_id])
    Repo.query!("DELETE FROM platform.gateways WHERE gateway_id = $1", [status.gateway_id])
  end
end
