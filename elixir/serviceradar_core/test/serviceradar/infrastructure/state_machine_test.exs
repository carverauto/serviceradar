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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.{Agent, Checker, Gateway}

  @moduletag :database

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    # Tenant schema determined by DB connection's search_path
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:test)}
  end

  describe "Gateway state machine" do
    test "registers in healthy state", %{actor: actor} do
      {:ok, gateway} =
        Gateway
        |> Ash.Changeset.for_create(:register, %{
          id: "gateway-#{System.unique_integer([:positive])}"
        })
        |> Ash.create(actor: actor)

      assert gateway.status == :healthy
      assert gateway.is_healthy == true
    end

    test "transitions from healthy to degraded", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)
      assert gateway.status == :healthy

      {:ok, degraded} = Ash.update(gateway, :degrade, %{reason: "test"}, actor: actor)

      assert degraded.status == :degraded
      assert degraded.is_healthy == false
    end

    test "transitions from healthy to offline", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      {:ok, offline} = Ash.update(gateway, :go_offline, %{reason: "shutdown"}, actor: actor)

      assert offline.status == :offline
      assert offline.is_healthy == false
    end

    test "transitions through maintenance cycle", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      # Start maintenance
      {:ok, in_maintenance} = Ash.update(gateway, :start_maintenance, %{}, actor: actor)
      assert in_maintenance.status == :maintenance

      # End maintenance
      {:ok, restored} = Ash.update(in_maintenance, :end_maintenance, %{}, actor: actor)
      assert restored.status == :healthy
      assert restored.is_healthy == true
    end

    test "transitions through draining cycle", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      # Start draining
      {:ok, draining} = Ash.update(gateway, :start_draining, %{}, actor: actor)
      assert draining.status == :draining

      # Finish draining
      {:ok, offline} = Ash.update(draining, :finish_draining, %{}, actor: actor)
      assert offline.status == :offline
    end

    test "transitions through recovery cycle", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      # Go offline
      {:ok, offline} = Ash.update(gateway, :go_offline, %{reason: "failure"}, actor: actor)
      assert offline.status == :offline

      # Start recovery
      {:ok, recovering} = Ash.update(offline, :recover, %{}, actor: actor)
      assert recovering.status == :recovering

      # Restore health
      {:ok, healthy} = Ash.update(recovering, :restore_health, %{}, actor: actor)
      assert healthy.status == :healthy
      assert healthy.is_healthy == true
    end

    test "deactivate works from any state", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      {:ok, inactive} = Ash.update(gateway, :deactivate, %{}, actor: actor)
      assert inactive.status == :inactive
      assert inactive.is_healthy == false
    end

    test "rejects invalid transitions", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      # Cannot recover from healthy (only from degraded/offline/recovering)
      {:error, changeset} = Ash.update(gateway, :recover, %{}, actor: actor)
      assert changeset.errors != []
    end

    defp create_healthy_gateway(actor) do
      Gateway
      |> Ash.Changeset.for_create(:register, %{
        id: "gateway-#{System.unique_integer([:positive])}"
      })
      |> Ash.create(actor: actor)
    end
  end

  describe "Agent state machine" do
    test "registers in connecting state by default", %{actor: actor} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "agent-#{System.unique_integer([:positive])}"
        })
        |> Ash.create(actor: actor)

      assert agent.status == :connecting
    end

    test "transitions from connecting to connected", %{actor: actor} do
      {:ok, agent} = create_connecting_agent(actor)

      {:ok, connected} = Ash.update(agent, :establish_connection, %{}, actor: actor)

      assert connected.status == :connected
      assert connected.is_healthy == true
    end

    test "transitions from connected to disconnected", %{actor: actor} do
      {:ok, agent} = create_connected_agent(actor)

      {:ok, disconnected} = Ash.update(agent, :lose_connection, %{}, actor: actor)

      assert disconnected.status == :disconnected
    end

    test "transitions through degradation cycle", %{actor: actor} do
      {:ok, agent} = create_connected_agent(actor)

      # Degrade
      {:ok, degraded} = Ash.update(agent, :degrade, %{}, actor: actor)
      assert degraded.status == :degraded
      assert degraded.is_healthy == false

      # Restore health
      {:ok, restored} = Ash.update(degraded, :restore_health, %{}, actor: actor)
      assert restored.status == :connected
      assert restored.is_healthy == true
    end

    test "transitions to unavailable and back", %{actor: actor} do
      {:ok, agent} = create_connected_agent(actor)

      # Mark unavailable
      {:ok, unavailable} = Ash.update(agent, :mark_unavailable, %{reason: "admin"}, actor: actor)
      assert unavailable.status == :unavailable
      assert unavailable.is_healthy == false

      # Recover
      {:ok, connecting} = Ash.update(unavailable, :recover, %{}, actor: actor)
      assert connecting.status == :connecting
    end

    defp create_connecting_agent(actor) do
      Agent
      |> Ash.Changeset.for_create(:register, %{
        uid: "agent-#{System.unique_integer([:positive])}"
      })
      |> Ash.create(actor: actor)
    end

    defp create_connected_agent(actor) do
      Agent
      |> Ash.Changeset.for_create(:register_connected, %{
        uid: "agent-#{System.unique_integer([:positive])}"
      })
      |> Ash.create(actor: actor)
    end
  end

  describe "Checker state machine" do
    test "creates in active state", %{actor: actor} do
      {:ok, checker} =
        Checker
        |> Ash.Changeset.for_create(:create, %{
          name: "Test Checker",
          type: "ping"
        })
        |> Ash.create(actor: actor)

      assert checker.status == :active
      assert checker.consecutive_failures == 0
    end

    test "transitions from active to paused", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)

      {:ok, paused} = Ash.update(checker, :pause, %{}, actor: actor)

      assert paused.status == :paused
    end

    test "transitions from paused to active", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)
      {:ok, paused} = Ash.update(checker, :pause, %{}, actor: actor)

      {:ok, resumed} = Ash.update(paused, :resume, %{}, actor: actor)

      assert resumed.status == :active
      assert resumed.enabled == true
    end

    test "transitions to failing state", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)

      {:ok, failing} = Ash.update(checker, :mark_failing, %{reason: "timeout"}, actor: actor)

      assert failing.status == :failing
      assert failing.failure_reason == "timeout"
      assert failing.last_failure != nil
    end

    test "clears failure state", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)
      {:ok, failing} = Ash.update(checker, :mark_failing, %{reason: "timeout"}, actor: actor)

      {:ok, cleared} = Ash.update(failing, :clear_failure, %{}, actor: actor)

      assert cleared.status == :active
      assert cleared.consecutive_failures == 0
      assert cleared.failure_reason == nil
      assert cleared.last_success != nil
    end

    test "records success resets consecutive failures", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)

      # Record some failures first
      {:ok, with_failures} =
        checker
        |> Ash.Changeset.for_update(:update, %{consecutive_failures: 5})
        |> Ash.update(actor: actor)

      # Record success
      {:ok, success} = Ash.update(with_failures, :record_success, %{}, actor: actor)

      assert success.consecutive_failures == 0
      assert success.last_success != nil
    end

    test "records failure increments consecutive failures", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)

      {:ok, failed_once} = Ash.update(checker, :record_failure, %{reason: "timeout"}, actor: actor)
      assert failed_once.consecutive_failures == 1

      {:ok, failed_twice} = Ash.update(failed_once, :record_failure, %{reason: "timeout"}, actor: actor)
      assert failed_twice.consecutive_failures == 2
    end

    test "disable and enable cycle", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)

      # Disable
      {:ok, disabled} = Ash.update(checker, :disable, %{}, actor: actor)
      assert disabled.status == :disabled
      assert disabled.enabled == false

      # Enable
      {:ok, enabled} = Ash.update(disabled, :enable, %{}, actor: actor)
      assert enabled.status == :active
      assert enabled.enabled == true
    end

    defp create_active_checker(actor) do
      Checker
      |> Ash.Changeset.for_create(:create, %{
        name: "Test Checker #{System.unique_integer([:positive])}",
        type: "ping"
      })
      |> Ash.create(actor: actor)
    end
  end
end
