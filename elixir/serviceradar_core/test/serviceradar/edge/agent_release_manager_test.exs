defmodule ServiceRadar.Edge.AgentReleaseManagerTest do
  use ExUnit.Case, async: false

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  defmodule TestControlSession do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end

    @impl true
    def init(opts) do
      {:ok, %{test_pid: opts[:test_pid]}}
    end

    @impl true
    def handle_call({:send_command, command, context}, _from, state) do
      send(state.test_pid, {:send_command, command, context})
      {:reply, {:ok, command.command_id}, state}
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:agent_release_manager_test)
    agent_id = "agent-release-#{System.unique_integer([:positive])}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register_connected, %{
        uid: agent_id,
        name: agent_id,
        version: "1.0.0",
        type_id: 4,
        type: "Performance",
        capabilities: ["agent"],
        metadata: %{"os" => "linux", "arch" => "amd64"}
      })
      |> Ash.create(actor: actor)

    {:ok, release} =
      AgentReleaseManager.publish_release(%{
        version: "1.1.0",
        signature: "sig-1",
        manifest: %{
          "version" => "1.1.0",
          "artifacts" => [
            %{
              "os" => "linux",
              "arch" => "amd64",
              "url" => "https://example.test/releases/agent-1.1.0-linux-amd64.tar.gz",
              "sha256" => "abc123"
            }
          ]
        }
      })

    {:ok, actor: actor, agent_id: agent_id, release: release}
  end

  test "create_rollout snapshots agents and dispatches to connected sessions", %{
    actor: actor,
    agent_id: agent_id,
    release: release
  } do
    {_pid, _metadata} = start_control_session(agent_id, self())

    assert {:ok, rollout} =
             AgentReleaseManager.create_rollout(%{
               release_id: release.id,
               agent_ids: [agent_id],
               batch_size: 1
             })

    assert_receive {:send_command, command, context}, 1_000
    assert command.command_type == "agent.update_release"
    payload = Jason.decode!(command.payload_json)

    assert payload["version"] == "1.1.0"
    assert payload["artifact"]["url"] =~ "agent-1.1.0-linux-amd64"
    assert context.desired_version == "1.1.0"

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(agent_id == ^agent_id and rollout_id == ^rollout.id))
      |> Ash.read_one!(actor: actor)

    assert target.status == :dispatched
    assert target.command_id

    updated_agent = Agent.get_by_uid!(agent_id, actor: actor)
    assert updated_agent.desired_version == "1.1.0"
    assert updated_agent.release_rollout_state == :dispatched
  end

  test "result updates target and agent state", %{
    actor: actor,
    agent_id: agent_id,
    release: release
  } do
    {_pid, _metadata} = start_control_session(agent_id, self())

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(%{
        release_id: release.id,
        agent_ids: [agent_id],
        batch_size: 1
      })

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(agent_id == ^agent_id and rollout_id == ^rollout.id))
      |> Ash.read_one!(actor: actor)

    :ok =
      AgentReleaseManager.handle_command_progress(%{
        command_type: "agent.update_release",
        command_id: target.command_id,
        message: "verifying",
        progress_percent: 55
      })

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :verifying
    assert target.progress_percent == 55

    :ok =
      AgentReleaseManager.handle_command_result(%{
        command_type: "agent.update_release",
        command_id: target.command_id,
        success: true,
        message: "release activated",
        payload: %{"current_version" => "1.1.0"}
      })

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :healthy

    updated_agent = Agent.get_by_uid!(agent_id, actor: actor)
    assert updated_agent.release_rollout_state == :healthy
    assert updated_agent.desired_version == "1.1.0"

    rollout = AgentReleaseRollout.get_by_id!(rollout.id, actor: actor)
    assert rollout.status == :completed
  end

  test "staged result remains inflight until activation completes", %{
    actor: actor,
    agent_id: agent_id,
    release: release
  } do
    {_pid, _metadata} = start_control_session(agent_id, self())

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(%{
        release_id: release.id,
        agent_ids: [agent_id],
        batch_size: 1
      })

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(agent_id == ^agent_id and rollout_id == ^rollout.id))
      |> Ash.read_one!(actor: actor)

    :ok =
      AgentReleaseManager.handle_command_result(%{
        command_type: "agent.update_release",
        command_id: target.command_id,
        success: true,
        message: "release staged",
        payload: %{"status" => "staged", "version" => "1.1.0"}
      })

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :staged

    updated_agent = Agent.get_by_uid!(agent_id, actor: actor)
    assert updated_agent.release_rollout_state == :staged

    rollout = AgentReleaseRollout.get_by_id!(rollout.id, actor: actor)
    assert rollout.status == :active
  end

  test "reconcile_agent dispatches a pending rollout after a session registers", %{
    actor: actor,
    agent_id: agent_id,
    release: release
  } do
    assert {:ok, rollout} =
             AgentReleaseManager.create_rollout(%{
               release_id: release.id,
               agent_ids: [agent_id],
               batch_size: 1
             })

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(agent_id == ^agent_id and rollout_id == ^rollout.id))
      |> Ash.read_one!(actor: actor)

    assert target.status == :pending

    {_pid, _metadata} = start_control_session(agent_id, self())

    assert :ok = AgentReleaseManager.reconcile_agent(agent_id)

    assert_receive {:send_command, command, _context}, 1_000
    assert command.command_type == "agent.update_release"

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :dispatched
  end

  defp start_control_session(agent_id, test_pid) do
    metadata = %{
      partition_id: "default",
      capabilities: ["agent"],
      connected_at: DateTime.utc_now()
    }

    name = ProcessRegistry.via({:agent_control, agent_id}, metadata)
    {:ok, pid} = TestControlSession.start_link(name: name, test_pid: test_pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {pid, metadata}
  end
end
