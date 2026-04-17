defmodule ServiceRadar.Edge.AgentCommandBusTest do
  @moduledoc """
  Integration tests for command bus dispatch, status updates, and push-config delivery.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.StatusHandler
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

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

    @impl true
    def handle_call({:push_config, response}, _from, state) do
      send(state.test_pid, {:push_config, response})
      {:reply, :ok, state}
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    agent_id = "agent-#{System.unique_integer([:positive])}"
    actor = SystemActor.system(:agent_command_bus_test)
    {:ok, agent_id: agent_id, actor: actor}
  end

  describe "offline dispatch" do
    test "fails fast and marks command offline", %{agent_id: agent_id, actor: actor} do
      command_type = "test.offline"

      assert {:error, {:agent_offline, ^agent_id}} =
               AgentCommandBus.dispatch(agent_id, command_type, %{reason: "offline"})

      command =
        AgentCommand
        |> Ash.Query.filter(agent_id == ^agent_id and command_type == ^command_type)
        |> Ash.read!(actor: actor)
        |> List.first()

      assert command
      assert command.status == :offline
      assert command.failure_reason == "agent_offline"
    end
  end

  describe "command status updates" do
    test "ack, progress, and result persist lifecycle", %{agent_id: agent_id, actor: actor} do
      ensure_status_handler_started()

      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mapper"]
        })

      assert {:ok, command_id} =
               AgentCommandBus.dispatch(agent_id, "test.run", %{payload: "ok"})

      command = wait_for_status(command_id, :sent, actor)
      assert command.agent_id == agent_id

      send(StatusHandler, {:command_ack, %{command_id: command_id, message: "ack"}})
      command = wait_for_status(command_id, :acknowledged, actor)
      assert command.message == "ack"

      send(
        StatusHandler,
        {:command_progress, %{command_id: command_id, message: "running", progress_percent: 42}}
      )

      command = wait_for_status(command_id, :running, actor)
      assert command.progress_percent == 42

      send(
        StatusHandler,
        {:command_result,
         %{command_id: command_id, success: true, message: "done", payload: %{"ok" => true}}}
      )

      command = wait_for_status(command_id, :completed, actor)
      assert command.message == "done"
      assert command.result_payload == %{"ok" => true}
    end

    test "blocks mtr dispatches beyond the agent concurrency limit", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      assert {:ok, first_command_id} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "1.1.1.1"})

      assert {:ok, second_command_id} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "8.8.8.8"})

      assert {:error, {:agent_busy, :too_many_concurrent_mtr_traces}} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "9.9.9.9"})

      _ = wait_for_status(first_command_id, :sent, actor)
      _ = wait_for_status(second_command_id, :sent, actor)

      commands =
        AgentCommand
        |> Ash.Query.filter(agent_id == ^agent_id and command_type == "mtr.run")
        |> Ash.read!(actor: actor)

      assert length(commands) == 2
      assert Enum.all?(commands, &(&1.status == :sent))
    end

    test "expired active mtr commands do not count toward the concurrency limit", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      _stale_one =
        create_mtr_command(actor, agent_id, "1.1.1.1",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
          status: :sent
        )

      _stale_two =
        create_mtr_command(actor, agent_id, "8.8.8.8",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
          status: :acknowledged
        )

      assert {:ok, command_id} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "9.9.9.9"})

      command = wait_for_status(command_id, :sent, actor)
      assert command.agent_id == agent_id
    end

    test "bulk mtr dispatch normalizes targets and persists queued target rows", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      assert {:ok, command_id} =
               AgentCommandBus.dispatch_bulk_mtr(
                 agent_id,
                 [" 1.1.1.1 ", "1.1.1.1", "", "router-a"],
                 protocol: "udp",
                 concurrency: 24,
                 context: %{"mtr_policy_id" => "policy-1"}
               )

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      assert command.command_type == "mtr.bulk_run"

      payload = Jason.decode!(command.payload_json)

      assert payload["targets"] == ["1.1.1.1", "router-a"]
      assert payload["protocol"] == "udp"
      assert payload["concurrency"] == 24
      assert context.mtr_policy_id == "policy-1"

      command = wait_for_status(command_id, :sent, actor)

      assert {:ok, %{rows: rows}} =
               ServiceRadar.Repo.query(
                 """
                 SELECT target, status
                 FROM platform.mtr_bulk_job_targets
                 WHERE command_id = $1
                 ORDER BY target
                 """,
                 [command.id]
               )

      assert rows == [["1.1.1.1", "queued"], ["router-a", "queued"]]
    end

    test "bulk mtr progress persists multiple target updates", %{
      agent_id: agent_id,
      actor: actor
    } do
      ensure_status_handler_started()

      command =
        create_bulk_mtr_command(actor, agent_id, ["1.1.1.1", "router-a"], status: :acknowledged)

      send(
        StatusHandler,
        {:command_progress,
         %{
           command_id: command.id,
           command_type: "mtr.bulk_run",
           message: "running",
           progress_percent: 50,
           payload: %{
             "target_updates" => [
               %{"target" => "1.1.1.1", "status" => "running", "attempt_count" => 1},
               %{
                 "target" => "router-a",
                 "status" => "completed",
                 "attempt_count" => 1,
                 "result_payload" => %{"summary" => "ok"}
               }
             ]
           }
         }}
      )

      _command = wait_for_status(command.id, :running, actor)

      assert {:ok, %{rows: rows}} =
               ServiceRadar.Repo.query(
                 """
                 SELECT target, status, result_payload
                 FROM platform.mtr_bulk_job_targets
                 WHERE command_id = $1
                 ORDER BY target
                 """,
                 [command.id]
               )

      assert rows == [
               ["1.1.1.1", "running", nil],
               ["router-a", "completed", %{"summary" => "ok"}]
             ]
    end

    test "blocks bulk mtr dispatches while another bulk job is active", %{
      agent_id: agent_id
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      assert {:ok, _command_id} =
               AgentCommandBus.dispatch_bulk_mtr(agent_id, ["1.1.1.1", "1.1.1.2"])

      assert {:error, {:agent_busy, :bulk_mtr_job_running}} =
               AgentCommandBus.dispatch_bulk_mtr(agent_id, ["8.8.8.8"])
    end

    test "expired active bulk mtr commands do not block dispatch", %{
      agent_id: agent_id
    } do
      actor = SystemActor.system(:agent_command_bus_test)

      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      create_bulk_mtr_command(actor, agent_id, ["1.1.1.1", "1.1.1.2"],
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        status: :sent
      )

      assert {:ok, _command_id} =
               AgentCommandBus.dispatch_bulk_mtr(agent_id, ["9.9.9.9"])
    end

    test "automation dispatches bypass the on-demand mtr concurrency limit", %{
      agent_id: agent_id,
      actor: actor
    } do
      {_pid, _metadata} =
        start_control_session(agent_id, self(), %{
          partition_id: "default",
          capabilities: ["mtr"]
        })

      baseline_context = %{"trigger_mode" => "baseline", "target_key" => "device:uid-1"}

      assert {:ok, _} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "1.1.1.1"},
                 context: baseline_context,
                 source: :automation
               )

      assert {:ok, _} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "8.8.8.8"},
                 context: baseline_context,
                 source: :automation
               )

      assert {:ok, _} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "9.9.9.9"},
                 context: baseline_context,
                 source: :automation
               )

      assert {:ok, _} =
               AgentCommandBus.dispatch(agent_id, "mtr.run", %{target: "2.2.2.2"},
                 context: %{"device_uid" => "ui-request"}
               )

      commands =
        AgentCommand
        |> Ash.Query.filter(agent_id == ^agent_id and command_type == "mtr.run")
        |> Ash.read!(actor: actor)

      assert length(commands) == 4
    end
  end

  describe "push-config delivery" do
    test "pushes config over control stream", %{agent_id: agent_id} do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})

      assert :ok = AgentCommandBus.push_config(agent_id)

      assert_receive {:push_config, %Monitoring.AgentConfigResponse{} = response}, 1_000
      assert is_binary(response.config_version)
    end
  end

  describe "camera relay dispatch" do
    test "sends a typed camera open relay command", %{agent_id: agent_id} do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})

      assert {:ok, _command_id} =
               AgentCommandBus.start_camera_relay(agent_id, %{
                 relay_session_id: "relay-1",
                 camera_source_id: "camera-1",
                 stream_profile_id: "main",
                 lease_token: "lease-1",
                 source_url: "rtsp://camera.local/stream/main",
                 rtsp_transport: "tcp",
                 codec_hint: "h264"
               })

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      assert command.command_type == "camera.open_relay"

      payload = Jason.decode!(command.payload_json)

      assert payload["relay_session_id"] == "relay-1"
      assert payload["camera_source_id"] == "camera-1"
      assert payload["stream_profile_id"] == "main"
      assert payload["lease_token"] == "lease-1"
      assert payload["source_url"] == "rtsp://camera.local/stream/main"
      assert payload["rtsp_transport"] == "tcp"
      assert payload["codec_hint"] == "h264"

      assert context.relay_session_id == "relay-1"
      assert context.camera_source_id == "camera-1"
      assert context.stream_profile_id == "main"
      assert context.source_url == "rtsp://camera.local/stream/main"
    end

    test "resolves source_url from camera inventory before dispatch", %{agent_id: agent_id} do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})
      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()

      fetcher = fn ^camera_source_id, ^stream_profile_id ->
        {:ok,
         %{
           source_url_override: nil,
           rtsp_transport: "tcp",
           codec_hint: "h264",
           container_hint: "annexb",
           camera_source: %{source_url: "rtsp://camera.local/inventory/main"}
         }}
      end

      assert {:ok, _command_id} =
               AgentCommandBus.start_camera_relay(
                 agent_id,
                 %{
                   relay_session_id: "relay-2",
                   camera_source_id: camera_source_id,
                   stream_profile_id: stream_profile_id,
                   lease_token: "lease-2"
                 },
                 camera_profile_fetcher: fetcher
               )

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      payload = Jason.decode!(command.payload_json)

      assert payload["source_url"] == "rtsp://camera.local/inventory/main"
      assert payload["rtsp_transport"] == "tcp"
      assert payload["codec_hint"] == "h264"
      assert payload["container_hint"] == "annexb"
      assert context.source_url == "rtsp://camera.local/inventory/main"
    end

    test "sends a typed camera close relay command", %{agent_id: agent_id} do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})

      assert {:ok, _command_id} =
               AgentCommandBus.stop_camera_relay(agent_id, %{
                 relay_session_id: "relay-1",
                 reason: "viewer disconnected"
               })

      assert_receive {:send_command, %Monitoring.CommandRequest{} = command, context}, 1_000
      assert command.command_type == "camera.close_relay"

      payload = Jason.decode!(command.payload_json)

      assert payload["relay_session_id"] == "relay-1"
      assert payload["reason"] == "viewer disconnected"
      assert context.relay_session_id == "relay-1"
    end
  end

  defp ensure_status_handler_started do
    case Process.whereis(StatusHandler) do
      nil -> StatusHandler.start_link([])
      _pid -> :ok
    end
  end

  defp start_control_session(agent_id, test_pid, metadata) do
    name = ProcessRegistry.via({:agent_control, agent_id}, metadata)
    {:ok, pid} = TestControlSession.start_link(name: name, test_pid: test_pid)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    {pid, metadata}
  end

  defp create_mtr_command(actor, agent_id, target, opts) do
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 60, :second))
    status = Keyword.get(opts, :status, :queued)

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"target" => target},
          ttl_seconds: 60,
          expires_at: expires_at
        },
        actor: actor
      )

    case status do
      :queued ->
        command

      :sent ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        command

      :acknowledged ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        {:ok, command} = AgentCommand.acknowledge(command, [message: "ack"], actor: actor)
        command
    end
  end

  defp create_bulk_mtr_command(actor, agent_id, targets, opts) do
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 300, :second))
    status = Keyword.get(opts, :status, :queued)

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.bulk_run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"targets" => targets, "protocol" => "icmp"},
          ttl_seconds: 300,
          expires_at: expires_at
        },
        actor: actor
      )

    case status do
      :queued ->
        command

      :sent ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        command

      :acknowledged ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        {:ok, command} = AgentCommand.acknowledge(command, [message: "ack"], actor: actor)
        command
    end
  end

  defp wait_for_status(command_id, expected_status, actor) do
    Enum.reduce_while(1..20, nil, fn _, _ ->
      case AgentCommand.get_by_id(command_id, actor: actor) do
        {:ok, %{status: ^expected_status} = command} ->
          {:halt, command}

        _ ->
          Process.sleep(50)
          {:cont, nil}
      end
    end) || flunk("Expected command #{command_id} to reach status #{inspect(expected_status)}")
  end
end
