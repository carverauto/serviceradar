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
  end

  describe "push-config delivery" do
    test "pushes config over control stream", %{agent_id: agent_id} do
      {_pid, _metadata} = start_control_session(agent_id, self(), %{partition_id: "default"})

      assert :ok = AgentCommandBus.push_config(agent_id)

      assert_receive {:push_config, %Monitoring.AgentConfigResponse{} = response}, 1_000
      assert is_binary(response.config_version)
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
