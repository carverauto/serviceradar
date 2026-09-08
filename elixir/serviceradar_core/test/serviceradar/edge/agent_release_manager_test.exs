defmodule ServiceRadar.Edge.AgentReleaseManagerTest do
  use ServiceRadar.DataCase, async: false

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentTracker
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Edge.ReleaseArtifactDelivery
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
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
    previous_public_key =
      Application.fetch_env(:serviceradar_core, :agent_release_public_key)

    previous_mirror_module =
      Application.fetch_env(:serviceradar_core, :agent_release_artifact_mirror_module)

    TestSupport.start_core!()
    Application.put_env(:serviceradar_core, :agent_release_public_key, @release_public_key)

    Application.put_env(
      :serviceradar_core,
      :agent_release_artifact_mirror_module,
      TestReleaseArtifactMirror
    )

    on_exit(fn ->
      restore_env_snapshot(:agent_release_public_key, previous_public_key)
      restore_env_snapshot(:agent_release_artifact_mirror_module, previous_mirror_module)
    end)

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
    refute Map.has_key?(payload, "helper_install")
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

  test "create_rollout includes RDP helper install plan only for RDP artifacts", %{
    agent_id: agent_id
  } do
    previous = Application.get_env(:serviceradar_core, :remote_access_desktop_rdp_enabled)
    Application.put_env(:serviceradar_core, :remote_access_desktop_rdp_enabled, true)

    on_exit(fn ->
      restore_env(:remote_access_desktop_rdp_enabled, previous)
    end)

    release_attrs =
      signed_release_attrs("1.1.1",
        artifact: %{
          "capabilities" => ["agent", "remote_access.rdp"],
          "helper_protocol_version" => "srdp-helper-v1",
          "compatible_agent_versions" => %{"min" => "1.1.0", "max" => "1.2.x"},
          "deployment_requirements" => %{
            "helper" => "serviceradar-rdp-adapter",
            "install_path" => "/usr/local/bin/serviceradar-rdp-adapter",
            "helper_capabilities_arg" => "--capabilities",
            "helper_connector_ready" => false,
            "helper_connector_ready_reason" => "connector_loop_not_implemented",
            "requires_helper_readiness_probe" => true,
            "release_phase" => "experimental"
          }
        }
      )

    {:ok, release} = AgentReleaseManager.publish_release(release_attrs)
    {_pid, _metadata} = start_control_session(agent_id, self())

    assert {:ok, _rollout} =
             AgentReleaseManager.create_rollout(%{
               release_id: release.id,
               agent_ids: [agent_id],
               batch_size: 1
             })

    assert_receive {:send_command, command, _context}, 1_000
    payload = Jason.decode!(command.payload_json)

    assert payload["artifact"]["capabilities"] == ["agent", "remote_access.rdp"]

    assert payload["helper_install"] == %{
             "enabled" => true,
             "capability" => "remote_access.rdp",
             "helper_protocol_version" => "srdp-helper-v1",
             "compatible_agent_versions" => %{"min" => "1.1.0", "max" => "1.2.x"},
             "deployment_requirements" => %{
               "helper" => "serviceradar-rdp-adapter",
               "install_path" => "/usr/local/bin/serviceradar-rdp-adapter",
               "helper_capabilities_arg" => "--capabilities",
               "helper_connector_ready" => false,
               "helper_connector_ready_reason" => "connector_loop_not_implemented",
               "requires_helper_readiness_probe" => true,
               "release_phase" => "experimental"
             }
           }
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
    assert target.command_id == nil
    assert target.last_status_message == "waiting for agent control stream"
    assert target.last_error == "agent control stream is offline for #{agent_id}"

    {_pid, _metadata} = start_control_session(agent_id, self())

    assert :ok = AgentReleaseManager.reconcile_agent(agent_id)

    assert_receive {:send_command, command, _context}, 1_000
    assert command.command_type == "agent.update_release"

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :dispatched
  end

  test "reconcile_agent retries a release command that was sent but never acknowledged", %{
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

    assert_receive {:send_command, first_command, _context}, 1_000

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(expr(agent_id == ^agent_id and rollout_id == ^rollout.id))
      |> Ash.read_one!(actor: actor)

    assert target.status == :dispatched
    assert target.command_id == first_command.command_id

    Repo.query!(
      "UPDATE platform.agent_commands SET sent_at = NOW() - INTERVAL '2 minutes' WHERE command_id = $1::uuid",
      [Ecto.UUID.dump!(target.command_id)]
    )

    assert :ok = AgentReleaseManager.reconcile_agent(agent_id)

    assert_receive {:send_command, second_command, _context}, 1_000
    assert second_command.command_type == "agent.update_release"
    refute second_command.command_id == first_command.command_id

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :dispatched
    assert target.command_id == second_command.command_id
    assert target.last_error == nil
  end

  test "handle_command_expired marks an inflight release target failed", %{
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

    command = AgentCommand.get_by_id!(target.command_id, actor: actor)

    assert :ok = AgentReleaseManager.handle_command_expired(command, actor: actor)

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :failed
    assert target.last_error == "command_expired"

    updated_agent = Agent.get_by_uid!(agent_id, actor: actor)
    assert updated_agent.release_rollout_state == :failed
    assert updated_agent.last_update_error == "command_expired"
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

  test "create_rollout ignores RDP artifacts unless remote access desktop is enabled", %{
    actor: actor,
    agent_id: agent_id
  } do
    original_enabled = Application.get_env(:serviceradar_core, :remote_access_desktop_rdp_enabled)

    on_exit(fn ->
      restore_env(:remote_access_desktop_rdp_enabled, original_enabled)
    end)

    version = "1.2.#{System.unique_integer([:positive])}"
    release_attrs = signed_release_attrs(version, capabilities: ["remote_access.rdp"])
    {:ok, release} = AgentReleaseManager.publish_release(release_attrs)

    Application.put_env(:serviceradar_core, :remote_access_desktop_rdp_enabled, false)

    assert {:error, %{errors: [%{message: unsupported_message}]}} =
             AgentReleaseManager.create_rollout(%{
               release_id: release.id,
               agent_ids: [agent_id],
               batch_size: 1
             })

    assert unsupported_message ==
             "unsupported agent platforms for release cohort: #{agent_id} (linux/amd64)"

    Application.put_env(:serviceradar_core, :remote_access_desktop_rdp_enabled, true)

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

    assert target
  end

  test "create_rollout uses live tracker platform metadata when persisted metadata is missing", %{
    actor: actor,
    release: release
  } do
    agent_id = "agent-release-live-platform-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      AgentTracker.remove_agent(agent_id)
    end)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Live Metadata Agent",
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{}
        },
        actor: actor
      )
      |> Ash.create()

    :ok =
      AgentTracker.track_agent(agent_id, %{
        version: "1.2.20",
        os: "linux",
        arch: "amd64"
      })

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

    assert target
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

  test "failed result completes a single-target rollout even when batch delay is still open", %{
    actor: actor,
    agent_id: agent_id,
    release: release
  } do
    {_pid, _metadata} = start_control_session(agent_id, self())

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(%{
        release_id: release.id,
        agent_ids: [agent_id],
        batch_size: 1,
        batch_delay_seconds: 3_600
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
        message: "release manifest signature verification failed",
        payload: %{
          "status" => "failed",
          "reason" => "release manifest signature verification failed"
        }
      })

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :failed

    rollout = AgentReleaseRollout.get_by_id!(rollout.id, actor: actor)
    assert rollout.status == :completed
  end

  test "reconcile_agent completes a restarting rollout when the agent reconnects on the desired version",
       %{
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
        message: "restarting",
        progress_percent: 95
      })

    {:ok, target} =
      AgentReleaseTarget.set_status(
        target,
        %{status: :restarting, last_error: "command_ack_timeout"},
        actor: actor
      )

    agent = Agent.get_by_uid!(agent_id, actor: actor)

    {:ok, _agent} =
      agent
      |> Ash.Changeset.for_update(
        :update_release_status,
        %{
          desired_version: release.version,
          release_rollout_state: :restarting,
          version: release.version
        }
      )
      |> Ash.update(actor: actor)

    assert :ok = AgentReleaseManager.reconcile_agent(agent_id)

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :healthy
    assert target.progress_percent == 100
    assert target.last_error == nil

    rollout = AgentReleaseRollout.get_by_id!(rollout.id, actor: actor)
    assert rollout.status == :completed
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

  test "retry_target re-dispatches a failed target and reactivates the rollout", %{
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

    assert_receive {:send_command, first_command, _context}, 1_000

    target = read_release_target(actor, agent_id, rollout.id)

    # Terminal (non-transient) failure so the target stays failed and the rollout completes.
    :ok =
      AgentReleaseManager.handle_command_result(%{
        command_type: "agent.update_release",
        command_id: first_command.command_id,
        success: false,
        message: "release manifest signature verification failed",
        payload: %{
          "status" => "failed",
          "reason" => "release manifest signature verification failed"
        }
      })

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :failed

    rollout = AgentReleaseRollout.get_by_id!(rollout.id, actor: actor)
    assert rollout.status == :completed

    assert {:ok, retried_target} = AgentReleaseManager.retry_target(target.id, actor: actor)
    assert retried_target.agent_id == agent_id

    assert_receive {:send_command, retry_command, _context}, 1_000
    refute retry_command.command_id == first_command.command_id

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :dispatched
    assert target.command_id == retry_command.command_id
    assert target.last_error == nil

    rollout = AgentReleaseRollout.get_by_id!(rollout.id, actor: actor)
    assert rollout.status == :active
  end

  test "retry_target rejects targets that are not in a failed state", %{
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

    target = read_release_target(actor, agent_id, rollout.id)
    assert target.status == :dispatched

    assert {:error, :target_not_retryable} =
             AgentReleaseManager.retry_target(target.id, actor: actor)
  end

  test "handle_command_result auto-retries a transient download failure then fails after the budget",
       %{actor: actor, agent_id: agent_id, release: release} do
    {_pid, _metadata} = start_control_session(agent_id, self())

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(%{
        release_id: release.id,
        agent_ids: [agent_id],
        batch_size: 1
      })

    assert_receive {:send_command, first_command, _context}, 1_000
    target = read_release_target(actor, agent_id, rollout.id)
    assert target.command_id == first_command.command_id

    # Each transient 403 auto-retries with a fresh command until the retry budget (3) is spent.
    last_command_id =
      Enum.reduce(1..3, first_command.command_id, fn expected_count, command_id ->
        :ok = fail_release_command(command_id, "download failed: status 403")

        assert_receive {:send_command, retry_command, _context}, 1_000
        refute retry_command.command_id == command_id

        retried_target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
        assert retried_target.status == :dispatched
        assert retried_target.metadata["auto_retry_count"] == expected_count

        retry_command.command_id
      end)

    # Budget exhausted: the next transient failure is terminal.
    :ok = fail_release_command(last_command_id, "download failed: status 403")
    refute_receive {:send_command, _command, _context}, 250

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :failed
    assert target.last_error =~ "status 403"
  end

  test "handle_command_result keeps a non-transient download failure terminal", %{
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

    assert_receive {:send_command, command, _context}, 1_000
    target = read_release_target(actor, agent_id, rollout.id)

    :ok = fail_release_command(command.command_id, "release artifact platform does not match")

    refute_receive {:send_command, _command, _context}, 250

    target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
    assert target.status == :failed
    assert target.last_error == "release artifact platform does not match"
  end

  test "resolve_download classifies not-ready/lookup failures as retryable, not a terminal 403",
       %{actor: actor, agent_id: agent_id, release: release} do
    {_pid, _metadata} = start_control_session(agent_id, self())

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(%{
        release_id: release.id,
        agent_ids: [agent_id],
        batch_size: 1
      })

    assert_receive {:send_command, _command, _context}, 1_000
    target = read_release_target(actor, agent_id, rollout.id)

    assert {:ok, download} =
             ReleaseArtifactDelivery.resolve_download(target.id, target.command_id, agent_id)

    assert download.agent_id == agent_id
    assert is_binary(download.object_key)

    # A genuine authorization denial (wrong caller) stays a terminal 403.
    assert {:error, :unauthorized} =
             ReleaseArtifactDelivery.resolve_download(
               target.id,
               target.command_id,
               "agent-someone-else"
             )

    # A target that is not visible (read race / not staged) is retryable, not a 403.
    assert {:error, :artifact_not_ready} =
             ReleaseArtifactDelivery.resolve_download(
               Ecto.UUID.generate(),
               target.command_id,
               agent_id
             )
  end

  defp read_release_target(actor, agent_id, rollout_id) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(expr(agent_id == ^agent_id and rollout_id == ^rollout_id))
    |> Ash.read_one!(actor: actor)
  end

  defp fail_release_command(command_id, reason) do
    AgentReleaseManager.handle_command_result(%{
      command_type: "agent.update_release",
      command_id: command_id,
      success: false,
      message: reason,
      payload: %{"status" => "failed", "reason" => reason}
    })
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
      agent_id: agent_id,
      partition_id: "default",
      capabilities: ["agent"],
      connected_at: DateTime.utc_now()
    }

    name = ProcessRegistry.via({:agent_control, "default", agent_id, node()}, metadata)
    {:ok, pid} = TestControlSession.start_link(name: name, test_pid: test_pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {pid, metadata}
  end

  defp signed_release_attrs(version, opts \\ []) do
    artifact =
      %{
        "os" => "linux",
        "arch" => "amd64",
        "url" => "https://example.com/releases/agent-#{version}-linux-amd64.tar.gz",
        "sha256" => String.duplicate("a", 64)
      }
      |> maybe_put_capabilities(Keyword.get(opts, :capabilities, []))
      |> Map.merge(Keyword.get(opts, :artifact, %{}))
      |> maybe_put_rdp_metadata(version)

    manifest = %{
      "version" => version,
      "artifacts" => [artifact]
    }

    %{
      version: version,
      manifest: manifest,
      signature: sign_manifest(manifest)
    }
  end

  defp maybe_put_capabilities(artifact, []), do: artifact

  defp maybe_put_capabilities(artifact, capabilities),
    do: Map.put(artifact, "capabilities", capabilities)

  defp maybe_put_rdp_metadata(%{"capabilities" => capabilities} = artifact, version)
       when is_list(capabilities) do
    if "remote_access.rdp" in capabilities or "remote_access.desktop" in capabilities do
      deployment_requirements =
        Map.merge(
          %{
            "helper" => "serviceradar-rdp-adapter",
            "install_path" => "/usr/local/bin/serviceradar-rdp-adapter",
            "helper_capabilities_arg" => "--capabilities",
            "helper_connector_ready" => false,
            "helper_connector_ready_reason" => "connector_loop_not_implemented",
            "requires_helper_readiness_probe" => true,
            "release_phase" => "experimental"
          },
          Map.get(artifact, "deployment_requirements", %{})
        )

      artifact
      |> Map.put_new("helper_protocol_version", "srdp-helper-v1")
      |> Map.put_new("compatible_agent_versions", %{"min" => version, "max" => version})
      |> Map.put("deployment_requirements", deployment_requirements)
    else
      artifact
    end
  end

  defp maybe_put_rdp_metadata(artifact, _version), do: artifact

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)

  defp restore_env_snapshot(key, {:ok, value}),
    do: Application.put_env(:serviceradar_core, key, value)

  defp restore_env_snapshot(key, :error), do: Application.delete_env(:serviceradar_core, key)

  defp sign_manifest(manifest) do
    {:ok, payload} = ServiceRadar.Edge.ReleaseManifestValidator.canonical_json(manifest)
    private_key = Base.decode64!(@release_private_key)

    :eddsa
    |> :crypto.sign(:none, payload, [private_key, :ed25519])
    |> Base.encode64()
  end
end
