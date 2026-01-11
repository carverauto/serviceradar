defmodule ServiceRadar.Infrastructure.StateMachineTest do
  @moduledoc """
  Tests for infrastructure component state machines.

  Verifies:
  - Gateway state transitions
  - Agent state transitions
  - Checker state transitions
  - Invalid transition handling
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Infrastructure.{Gateway, Agent, Checker}

  @moduletag :database

  setup_all do
    tenant = ServiceRadar.TestSupport.create_tenant_schema!("infra-state")

    on_exit(fn ->
      ServiceRadar.TestSupport.drop_tenant_schema!(tenant.tenant_slug)
    end)

    {:ok, tenant_id: tenant.tenant_id}
  end

  setup %{tenant_id: tenant_id} do
    partition_id = Ash.UUID.generate()

    {:ok, tenant_id: tenant_id, partition_id: partition_id}
  end

  describe "Gateway state machine" do
    test "registers in healthy state", %{tenant_id: tenant_id} do
      {:ok, gateway} =
        Gateway
        |> Ash.Changeset.for_create(:register, %{
          id: "gateway-#{System.unique_integer([:positive])}"
        })
        |> Ash.create(authorize?: false, tenant: tenant_id)

      assert gateway.status == :healthy
      assert gateway.is_healthy == true
    end

    test "transitions from healthy to degraded", %{tenant_id: tenant_id} do
      {:ok, gateway} = create_healthy_gateway(tenant_id)
      assert gateway.status == :healthy

      {:ok, degraded} = Ash.update(gateway, :degrade, %{reason: "test"}, authorize?: false)

      assert degraded.status == :degraded
      assert degraded.is_healthy == false
    end

    test "transitions from healthy to offline", %{tenant_id: tenant_id} do
      {:ok, gateway} = create_healthy_gateway(tenant_id)

      {:ok, offline} = Ash.update(gateway, :go_offline, %{reason: "shutdown"}, authorize?: false)

      assert offline.status == :offline
      assert offline.is_healthy == false
    end

    test "transitions through maintenance cycle", %{tenant_id: tenant_id} do
      {:ok, gateway} = create_healthy_gateway(tenant_id)

      # Start maintenance
      {:ok, in_maintenance} = Ash.update(gateway, :start_maintenance, %{}, authorize?: false)
      assert in_maintenance.status == :maintenance

      # End maintenance
      {:ok, restored} = Ash.update(in_maintenance, :end_maintenance, %{}, authorize?: false)
      assert restored.status == :healthy
      assert restored.is_healthy == true
    end

    test "transitions through draining cycle", %{tenant_id: tenant_id} do
      {:ok, gateway} = create_healthy_gateway(tenant_id)

      # Start draining
      {:ok, draining} = Ash.update(gateway, :start_draining, %{}, authorize?: false)
      assert draining.status == :draining

      # Finish draining
      {:ok, offline} = Ash.update(draining, :finish_draining, %{}, authorize?: false)
      assert offline.status == :offline
    end

    test "transitions through recovery cycle", %{tenant_id: tenant_id} do
      {:ok, gateway} = create_healthy_gateway(tenant_id)

      # Go offline
      {:ok, offline} = Ash.update(gateway, :go_offline, %{reason: "failure"}, authorize?: false)
      assert offline.status == :offline

      # Start recovery
      {:ok, recovering} = Ash.update(offline, :recover, %{}, authorize?: false)
      assert recovering.status == :recovering

      # Restore health
      {:ok, healthy} = Ash.update(recovering, :restore_health, %{}, authorize?: false)
      assert healthy.status == :healthy
      assert healthy.is_healthy == true
    end

    test "deactivate works from any state", %{tenant_id: tenant_id} do
      {:ok, gateway} = create_healthy_gateway(tenant_id)

      {:ok, inactive} = Ash.update(gateway, :deactivate, %{}, authorize?: false)
      assert inactive.status == :inactive
      assert inactive.is_healthy == false
    end

    test "rejects invalid transitions", %{tenant_id: tenant_id} do
      {:ok, gateway} = create_healthy_gateway(tenant_id)

      # Cannot recover from healthy (only from degraded/offline/recovering)
      {:error, changeset} = Ash.update(gateway, :recover, %{}, authorize?: false)
      assert changeset.errors != []
    end

    defp create_healthy_gateway(tenant_id) do
      Gateway
      |> Ash.Changeset.for_create(:register, %{
        id: "gateway-#{System.unique_integer([:positive])}"
      })
      |> Ash.create(authorize?: false, tenant: tenant_id)
    end
  end

  describe "Agent state machine" do
    test "registers in connecting state by default", %{tenant_id: tenant_id} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "agent-#{System.unique_integer([:positive])}",
          tenant_id: tenant_id
        })
        |> Ash.create(authorize?: false)

      assert agent.status == :connecting
    end

    test "transitions from connecting to connected", %{tenant_id: tenant_id} do
      {:ok, agent} = create_connecting_agent(tenant_id)

      {:ok, connected} = Ash.update(agent, :establish_connection, %{}, authorize?: false)

      assert connected.status == :connected
      assert connected.is_healthy == true
    end

    test "transitions from connected to disconnected", %{tenant_id: tenant_id} do
      {:ok, agent} = create_connected_agent(tenant_id)

      {:ok, disconnected} = Ash.update(agent, :lose_connection, %{}, authorize?: false)

      assert disconnected.status == :disconnected
    end

    test "transitions through degradation cycle", %{tenant_id: tenant_id} do
      {:ok, agent} = create_connected_agent(tenant_id)

      # Degrade
      {:ok, degraded} = Ash.update(agent, :degrade, %{}, authorize?: false)
      assert degraded.status == :degraded
      assert degraded.is_healthy == false

      # Restore health
      {:ok, restored} = Ash.update(degraded, :restore_health, %{}, authorize?: false)
      assert restored.status == :connected
      assert restored.is_healthy == true
    end

    test "transitions to unavailable and back", %{tenant_id: tenant_id} do
      {:ok, agent} = create_connected_agent(tenant_id)

      # Mark unavailable
      {:ok, unavailable} = Ash.update(agent, :mark_unavailable, %{reason: "admin"}, authorize?: false)
      assert unavailable.status == :unavailable
      assert unavailable.is_healthy == false

      # Recover
      {:ok, connecting} = Ash.update(unavailable, :recover, %{}, authorize?: false)
      assert connecting.status == :connecting
    end

    defp create_connecting_agent(tenant_id) do
      Agent
      |> Ash.Changeset.for_create(:register, %{
        uid: "agent-#{System.unique_integer([:positive])}",
        tenant_id: tenant_id
      })
      |> Ash.create(authorize?: false)
    end

    defp create_connected_agent(tenant_id) do
      Agent
      |> Ash.Changeset.for_create(:register_connected, %{
        uid: "agent-#{System.unique_integer([:positive])}",
        tenant_id: tenant_id
      })
      |> Ash.create(authorize?: false)
    end
  end

  describe "Checker state machine" do
    test "creates in active state", %{tenant_id: tenant_id} do
      {:ok, checker} =
        Checker
        |> Ash.Changeset.for_create(:create, %{
          name: "Test Checker",
          type: "ping",
          tenant_id: tenant_id
        })
        |> Ash.create(authorize?: false)

      assert checker.status == :active
      assert checker.consecutive_failures == 0
    end

    test "transitions from active to paused", %{tenant_id: tenant_id} do
      {:ok, checker} = create_active_checker(tenant_id)

      {:ok, paused} = Ash.update(checker, :pause, %{}, authorize?: false)

      assert paused.status == :paused
    end

    test "transitions from paused to active", %{tenant_id: tenant_id} do
      {:ok, checker} = create_active_checker(tenant_id)
      {:ok, paused} = Ash.update(checker, :pause, %{}, authorize?: false)

      {:ok, resumed} = Ash.update(paused, :resume, %{}, authorize?: false)

      assert resumed.status == :active
      assert resumed.enabled == true
    end

    test "transitions to failing state", %{tenant_id: tenant_id} do
      {:ok, checker} = create_active_checker(tenant_id)

      {:ok, failing} = Ash.update(checker, :mark_failing, %{reason: "timeout"}, authorize?: false)

      assert failing.status == :failing
      assert failing.failure_reason == "timeout"
      assert failing.last_failure != nil
    end

    test "clears failure state", %{tenant_id: tenant_id} do
      {:ok, checker} = create_active_checker(tenant_id)
      {:ok, failing} = Ash.update(checker, :mark_failing, %{reason: "timeout"}, authorize?: false)

      {:ok, cleared} = Ash.update(failing, :clear_failure, %{}, authorize?: false)

      assert cleared.status == :active
      assert cleared.consecutive_failures == 0
      assert cleared.failure_reason == nil
      assert cleared.last_success != nil
    end

    test "records success resets consecutive failures", %{tenant_id: tenant_id} do
      {:ok, checker} = create_active_checker(tenant_id)

      # Record some failures first
      {:ok, with_failures} =
        checker
        |> Ash.Changeset.for_update(:update, %{consecutive_failures: 5})
        |> Ash.update(authorize?: false)

      # Record success
      {:ok, success} = Ash.update(with_failures, :record_success, %{}, authorize?: false)

      assert success.consecutive_failures == 0
      assert success.last_success != nil
    end

    test "records failure increments consecutive failures", %{tenant_id: tenant_id} do
      {:ok, checker} = create_active_checker(tenant_id)

      {:ok, failed_once} = Ash.update(checker, :record_failure, %{reason: "timeout"}, authorize?: false)
      assert failed_once.consecutive_failures == 1

      {:ok, failed_twice} = Ash.update(failed_once, :record_failure, %{reason: "timeout"}, authorize?: false)
      assert failed_twice.consecutive_failures == 2
    end

    test "disable and enable cycle", %{tenant_id: tenant_id} do
      {:ok, checker} = create_active_checker(tenant_id)

      # Disable
      {:ok, disabled} = Ash.update(checker, :disable, %{}, authorize?: false)
      assert disabled.status == :disabled
      assert disabled.enabled == false

      # Enable
      {:ok, enabled} = Ash.update(disabled, :enable, %{}, authorize?: false)
      assert enabled.status == :active
      assert enabled.enabled == true
    end

    defp create_active_checker(tenant_id) do
      Checker
      |> Ash.Changeset.for_create(:create, %{
        name: "Test Checker #{System.unique_integer([:positive])}",
        type: "ping",
        tenant_id: tenant_id
      })
      |> Ash.create(authorize?: false)
    end
  end
end
