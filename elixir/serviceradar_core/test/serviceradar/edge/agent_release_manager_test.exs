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
  @release_public_key "ot8W1BsqSvXV7KEjLL+RkQz106lzcIJNCY91OXSqBpk="
  @release_private_key "kRqU4UnTUPjychwJGH4ZdsuijaxuGUNFPezyY+iSnBY="

  defmodule TestReleaseArtifactMirror do
    @moduledoc false

    def prepare_publish_attrs(attrs, _opts \\ []) do
      manifest = Map.get(attrs, :manifest) || Map.get(attrs, "manifest") || %{}

      artifact =
        manifest
        |> Map.get("artifacts", [])
        |> List.first()
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      metadata =
        (Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{})
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.put("storage", %{
          "status" => "mirrored",
          "backend" => "test",
          "artifact_count" => 1,
          "artifacts" => [
            Map.merge(artifact, %{
              "object_key" => "agent-releases/test/#{artifact["sha256"]}",
              "file_name" => "serviceradar-agent"
            })
          ]
        })

      {:ok, Map.put(attrs, :metadata, metadata)}
    end
  end

  defmodule TestControlSession do
    @moduledoc false
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
    Application.put_env(:serviceradar_core, :agent_release_public_key, @release_public_key)

    Application.put_env(
      :serviceradar_core,
      :agent_release_artifact_mirror_module,
      TestReleaseArtifactMirror
    )

    :ok
  end

  setup do
    actor = SystemActor.system(:agent_release_manager_test)
    agent_id = "agent-release-#{System.unique_integer([:positive])}"

    {:ok, _agent} = register_agent(actor, agent_id)

    release_attrs = signed_release_attrs("1.1.0")

    {:ok, release} = AgentReleaseManager.publish_release(release_attrs)

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
    assert payload["artifact_transport"]["kind"] == "gateway_https"
    assert context.desired_version == "1.1.0"

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(agent_id == ^agent_id and rollout_id == ^rollout.id))
      |> Ash.read_one!(actor: actor)

    assert target.status == :dispatched
    assert target.command_id
    assert payload["artifact_transport"]["target_id"] == target.id
    assert payload["artifact_transport"]["path"] == "/artifacts/releases/download"
    assert is_integer(payload["artifact_transport"]["port"])

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

  test "create_rollout rejects unsupported platform cohorts before any targets are created", %{
    actor: actor,
    release: release
  } do
    agent_id = "agent-release-arm64-#{System.unique_integer([:positive])}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "ARM64 Test Agent",
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "arm64"}
        },
        actor: actor
      )
      |> Ash.create()

    assert {:error, %{errors: [%{message: unsupported_message}]}} =
             AgentReleaseManager.create_rollout(%{
               release_id: release.id,
               agent_ids: [agent_id],
               batch_size: 1
             })

    assert unsupported_message ==
             "unsupported agent platforms for release cohort: #{agent_id} (linux/arm64)"

    assert [] ==
             AgentReleaseTarget
             |> Ash.Query.for_read(:read, %{}, actor: actor)
             |> Ash.Query.filter(expr(agent_id == ^agent_id))
             |> Ash.read!(actor: actor)

    updated_agent = Agent.get_by_uid!(agent_id, actor: actor)
    assert is_nil(updated_agent.release_rollout_state)
    assert is_nil(updated_agent.last_update_error)
  end

  test "create_rollout rejects unresolved custom agent ids before any targets are created", %{
    actor: actor,
    release: release
  } do
    missing_agent_id = "agent-release-missing-#{System.unique_integer([:positive])}"

    assert {:error, %{errors: [%{message: message}]}} =
             AgentReleaseManager.create_rollout(%{
               release_id: release.id,
               agent_ids: [missing_agent_id],
               batch_size: 1
             })

    assert message == "unresolved agent ids: #{missing_agent_id}"

    assert [] ==
             AgentReleaseTarget
             |> Ash.Query.for_read(:read, %{}, actor: actor)
             |> Ash.Query.filter(expr(agent_id == ^missing_agent_id))
             |> Ash.read!(actor: actor)
  end

  test "pause and resume gates future batch dispatches", %{
    actor: actor,
    agent_id: agent_id,
    release: release
  } do
    second_agent_id = "agent-release-#{System.unique_integer([:positive])}"
    {:ok, _agent} = register_agent(actor, second_agent_id)

    {_pid, _metadata} = start_control_session(agent_id, self())
    {_pid, _metadata} = start_control_session(second_agent_id, self())

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(%{
        release_id: release.id,
        agent_ids: [agent_id, second_agent_id],
        batch_size: 1
      })

    assert_receive {:send_command, first_command, _context}, 1_000

    assert {:ok, _rollout} = AgentReleaseManager.pause_rollout(rollout.id)

    :ok =
      AgentReleaseManager.handle_command_result(%{
        command_type: "agent.update_release",
        command_id: first_command.command_id,
        success: true,
        message: "release activated",
        payload: %{"current_version" => "1.1.0"}
      })

    refute_receive {:send_command, _command, _context}, 250

    second_target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(agent_id == ^second_agent_id and rollout_id == ^rollout.id))
      |> Ash.read_one!(actor: actor)

    assert second_target.status == :pending

    assert {:ok, _rollout} = AgentReleaseManager.resume_rollout(rollout.id)

    assert_receive {:send_command, second_command, _context}, 1_000
    assert second_command.command_type == "agent.update_release"
  end

  test "canary batching dispatches the next target only after the prior target completes", %{
    actor: actor,
    agent_id: agent_id,
    release: release
  } do
    second_agent_id = "agent-release-#{System.unique_integer([:positive])}"
    {:ok, _agent} = register_agent(actor, second_agent_id)

    {_pid, _metadata} = start_control_session(agent_id, self())
    {_pid, _metadata} = start_control_session(second_agent_id, self())

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(%{
        release_id: release.id,
        agent_ids: [agent_id, second_agent_id],
        batch_size: 1
      })

    assert_receive {:send_command, first_command, _context}, 1_000
    refute_receive {:send_command, _command, _context}, 250

    second_target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(agent_id == ^second_agent_id and rollout_id == ^rollout.id))
      |> Ash.read_one!(actor: actor)

    assert second_target.status == :pending

    :ok =
      AgentReleaseManager.handle_command_result(%{
        command_type: "agent.update_release",
        command_id: first_command.command_id,
        success: true,
        message: "release activated",
        payload: %{"current_version" => "1.1.0"}
      })

    assert_receive {:send_command, second_command, _context}, 1_000
    assert second_command.command_type == "agent.update_release"

    second_target = AgentReleaseTarget.get_by_id!(second_target.id, actor: actor)
    assert second_target.status == :dispatched
  end

  test "batch delay blocks the next cohort until the delay window opens", %{
    actor: actor,
    agent_id: agent_id,
    release: release
  } do
    second_agent_id = "agent-release-#{System.unique_integer([:positive])}"
    {:ok, _agent} = register_agent(actor, second_agent_id)

    {_pid, _metadata} = start_control_session(agent_id, self())
    {_pid, _metadata} = start_control_session(second_agent_id, self())

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(%{
        release_id: release.id,
        agent_ids: [agent_id, second_agent_id],
        batch_size: 1,
        batch_delay_seconds: 3_600
      })

    assert_receive {:send_command, first_command, _context}, 1_000

    :ok =
      AgentReleaseManager.handle_command_result(%{
        command_type: "agent.update_release",
        command_id: first_command.command_id,
        success: true,
        message: "release activated",
        payload: %{"current_version" => "1.1.0"}
      })

    refute_receive {:send_command, _command, _context}, 250

    second_target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(agent_id == ^second_agent_id and rollout_id == ^rollout.id))
      |> Ash.read_one!(actor: actor)

    assert second_target.status == :pending

    rollout = AgentReleaseRollout.get_by_id!(rollout.id, actor: actor)
    assert rollout.status == :active
  end

  test "rolled back result marks the target and rollout terminal", %{
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
        success: false,
        message: "release rolled back",
        payload: %{"status" => "rolled_back", "reason" => "health deadline exceeded"}
      })

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :rolled_back
    assert target.last_error == "health deadline exceeded"

    updated_agent = Agent.get_by_uid!(agent_id, actor: actor)
    assert updated_agent.release_rollout_state == :rolled_back
    assert updated_agent.last_update_error == "health deadline exceeded"

    rollout = AgentReleaseRollout.get_by_id!(rollout.id, actor: actor)
    assert rollout.status == :completed
  end

  defp register_agent(actor, agent_id) do
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

  defp signed_release_attrs(version) do
    manifest = %{
      "version" => version,
      "artifacts" => [
        %{
          "os" => "linux",
          "arch" => "amd64",
          "url" => "https://example.com/releases/agent-#{version}-linux-amd64.tar.gz",
          "sha256" => String.duplicate("a", 64)
        }
      ]
    }

    %{
      version: version,
      manifest: manifest,
      signature: sign_manifest(manifest)
    }
  end

  defp sign_manifest(manifest) do
    {:ok, payload} = ServiceRadar.Edge.ReleaseManifestValidator.canonical_json(manifest)
    private_key = Base.decode64!(@release_private_key)

    :eddsa
    |> :crypto.sign(:none, payload, [private_key, :ed25519])
    |> Base.encode64()
  end
end
