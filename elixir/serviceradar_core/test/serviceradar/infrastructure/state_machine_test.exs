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
    # Schema determined by DB connection's search_path
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

      {:ok, degraded} = update_with_action(gateway, :degrade, %{reason: "test"}, actor)

      assert degraded.status == :degraded
      assert degraded.is_healthy == false
    end

    test "transitions from healthy to offline", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      {:ok, offline} = update_with_action(gateway, :go_offline, %{reason: "shutdown"}, actor)

      assert offline.status == :offline
      assert offline.is_healthy == false
    end

    test "transitions through maintenance cycle", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      # Start maintenance
      {:ok, in_maintenance} = update_with_action(gateway, :start_maintenance, %{}, actor)
      assert in_maintenance.status == :maintenance

      # End maintenance
      {:ok, restored} = update_with_action(in_maintenance, :end_maintenance, %{}, actor)
      assert restored.status == :healthy
      assert restored.is_healthy == true
    end

    test "transitions through draining cycle", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      # Start draining
      {:ok, draining} = update_with_action(gateway, :start_draining, %{}, actor)
      assert draining.status == :draining

      # Finish draining
      {:ok, offline} = update_with_action(draining, :finish_draining, %{}, actor)
      assert offline.status == :offline
    end

    test "transitions through recovery cycle", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      # Go offline
      {:ok, offline} = update_with_action(gateway, :go_offline, %{reason: "failure"}, actor)
      assert offline.status == :offline

      # Start recovery
      {:ok, recovering} = update_with_action(offline, :recover, %{}, actor)
      assert recovering.status == :recovering

      # Restore health
      {:ok, healthy} = update_with_action(recovering, :restore_health, %{}, actor)
      assert healthy.status == :healthy
      assert healthy.is_healthy == true
    end

    test "deactivate works from any state", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      {:ok, inactive} = update_with_action(gateway, :deactivate, %{}, actor)
      assert inactive.status == :inactive
      assert inactive.is_healthy == false
    end

    test "rejects invalid transitions", %{actor: actor} do
      {:ok, gateway} = create_healthy_gateway(actor)

      # Cannot recover from healthy (only from degraded/offline/recovering)
      {:error, changeset} = update_with_action(gateway, :recover, %{}, actor)
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

      {:ok, connected} = update_with_action(agent, :establish_connection, %{}, actor)

      assert connected.status == :connected
      assert connected.is_healthy == true
    end

    test "transitions from connected to disconnected", %{actor: actor} do
      {:ok, agent} = create_connected_agent(actor)

      {:ok, disconnected} = update_with_action(agent, :lose_connection, %{}, actor)

      assert disconnected.status == :disconnected
    end

    test "transitions through degradation cycle", %{actor: actor} do
      {:ok, agent} = create_connected_agent(actor)

      # Degrade
      {:ok, degraded} = update_with_action(agent, :degrade, %{}, actor)
      assert degraded.status == :degraded
      assert degraded.is_healthy == false

      # Restore health
      {:ok, restored} = update_with_action(degraded, :restore_health, %{}, actor)
      assert restored.status == :connected
      assert restored.is_healthy == true
    end

    test "transitions to unavailable and back", %{actor: actor} do
      {:ok, agent} = create_connected_agent(actor)

      # Mark unavailable
      {:ok, unavailable} = update_with_action(agent, :mark_unavailable, %{reason: "admin"}, actor)
      assert unavailable.status == :unavailable
      assert unavailable.is_healthy == false

      # Recover
      {:ok, connecting} = update_with_action(unavailable, :recover, %{}, actor)
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

      {:ok, paused} = update_with_action(checker, :pause, %{}, actor)

      assert paused.status == :paused
    end

    test "transitions from paused to active", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)
      {:ok, paused} = update_with_action(checker, :pause, %{}, actor)

      {:ok, resumed} = update_with_action(paused, :resume, %{}, actor)

      assert resumed.status == :active
      assert resumed.enabled == true
    end

    test "transitions to failing state", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)

      {:ok, failing} = update_with_action(checker, :mark_failing, %{reason: "timeout"}, actor)

      assert failing.status == :failing
      assert failing.failure_reason == "timeout"
      assert failing.last_failure != nil
    end

    test "clears failure state", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)
      {:ok, failing} = update_with_action(checker, :mark_failing, %{reason: "timeout"}, actor)

      {:ok, cleared} = update_with_action(failing, :clear_failure, %{}, actor)

      assert cleared.status == :active
      assert cleared.consecutive_failures == 0
      assert cleared.failure_reason == nil
      assert cleared.last_success != nil
    end

    test "records success resets consecutive failures", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)

      {:ok, failed_once} =
        update_with_action(checker, :record_failure, %{reason: "timeout"}, actor)

      {:ok, failed_twice} =
        update_with_action(failed_once, :record_failure, %{reason: "timeout"}, actor)

      {:ok, with_failures} =
        update_with_action(failed_twice, :record_failure, %{reason: "timeout"}, actor)

      # Record success
      {:ok, success} = update_with_action(with_failures, :record_success, %{}, actor)

      assert success.consecutive_failures == 0
      assert success.last_success != nil
    end

    test "records failure increments consecutive failures", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)

      {:ok, failed_once} =
        update_with_action(checker, :record_failure, %{reason: "timeout"}, actor)

      assert failed_once.consecutive_failures == 1

      {:ok, failed_twice} =
        update_with_action(failed_once, :record_failure, %{reason: "timeout"}, actor)

      assert failed_twice.consecutive_failures == 2
    end

    test "disable and enable cycle", %{actor: actor} do
      {:ok, checker} = create_active_checker(actor)

      # Disable
      {:ok, disabled} = update_with_action(checker, :disable, %{}, actor)
      assert disabled.status == :disabled
      assert disabled.enabled == false

      # Enable
      {:ok, enabled} = update_with_action(disabled, :enable, %{}, actor)
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

  defp update_with_action(record, action, params, actor) do
    record
    |> Ash.Changeset.for_update(action, params, actor: actor)
    |> Ash.update(actor: actor)
  end
end
