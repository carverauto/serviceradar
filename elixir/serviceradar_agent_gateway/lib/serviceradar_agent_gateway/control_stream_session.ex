defmodule ServiceRadarAgentGateway.ControlStreamSession do
  @moduledoc """
  Tracks an agent control stream and routes command/config messages.
  """

  use GenServer

  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.ProcessRegistry

  require Logger

  @type state :: %{
          stream: GRPC.Server.Stream.t(),
          agent_id: String.t() | nil,
          partition_id: String.t() | nil,
          capabilities: [String.t()],
          commands: %{optional(String.t()) => map()},
          registry_key: term() | nil,
          gateway_node: String.t()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def register(pid, agent_id, partition_id, capabilities) do
    GenServer.call(pid, {:register, agent_id, partition_id, capabilities})
  end

  def handle_message(pid, %Monitoring.ControlStreamRequest{} = message) do
    GenServer.cast(pid, {:message, message})
  end

  def send_command(pid, %Monitoring.CommandRequest{} = command, context \\ %{}) do
    GenServer.call(pid, {:send_command, command, context})
  end

  def push_config(pid, %Monitoring.AgentConfigResponse{} = config) do
    GenServer.call(pid, {:push_config, config})
  end

  @impl true
  def init(opts) do
    stream = Keyword.fetch!(opts, :stream)

    {:ok,
     %{
       stream: stream,
       agent_id: nil,
       partition_id: nil,
       capabilities: [],
       commands: %{},
       registry_key: nil,
       gateway_node: Atom.to_string(node())
     }}
  end

  @impl true
  def handle_call({:register, agent_id, partition_id, capabilities}, _from, state) do
    metadata = %{
      agent_id: agent_id,
      partition_id: partition_id,
      capabilities: capabilities,
      connected_at: DateTime.utc_now(),
      gateway_node: state.gateway_node
    }

    key = {:agent_control, agent_id, node()}

    :ok = register_session(key, metadata)

    {:reply, :ok,
     %{
       state
       | agent_id: agent_id,
         partition_id: partition_id,
         capabilities: capabilities,
         registry_key: key
     }}
  end

  def handle_call({:send_command, command, context}, _from, state) do
    response = %Monitoring.ControlStreamResponse{payload: {:command, command}}

    case send_stream_reply(state.stream, response) do
      {:ok, stream} ->
        log_command_dispatch(state, command)

        {:reply, {:ok, command.command_id},
         track_command(%{state | stream: stream}, command, context)}

      {:error, reason} ->
        Logger.warning(
          "Failed to dispatch command to agent #{state.agent_id}: #{inspect(reason)}"
        )

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:push_config, config}, _from, state) do
    response = %Monitoring.ControlStreamResponse{payload: {:config, config}}

    case send_stream_reply(state.stream, response) do
      {:ok, stream} ->
        {:reply, :ok, %{state | stream: stream}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:message, %Monitoring.ControlStreamRequest{} = message}, state) do
    case message.payload do
      {:command_ack, ack} ->
        log_command_ack(state, ack)
        broadcast_ack(ack, state)
        {:noreply, state}

      {:command_progress, progress} ->
        log_command_progress(state, progress)
        broadcast_progress(progress, state)
        {:noreply, state}

      {:command_result, result} ->
        {command_meta, commands} = Map.pop(state.commands, result.command_id, %{})
        broadcast_result(result, command_meta, state)
        {:noreply, %{state | commands: commands}}

      {:config_ack, ack} ->
        Logger.debug("Agent config ack: agent_id=#{state.agent_id} version=#{ack.config_version}")
        {:noreply, state}

      {:hello, _hello} ->
        Logger.debug("Ignoring duplicate control stream hello")
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.registry_key do
      ProcessRegistry.unregister(state.registry_key)
    end

    :ok
  end

  defp register_session(key, metadata) do
    unregister_legacy_session_key(key)

    case ProcessRegistry.register(key, metadata) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        :ok

      {:error, {:already_registered, _pid}} ->
        ProcessRegistry.unregister(key)

        case ProcessRegistry.register(key, metadata) do
          {:ok, _pid} -> :ok
          {:error, {:already_registered, _pid}} -> :ok
        end
    end
  end

  defp unregister_legacy_session_key({:agent_control, agent_id, _node}) do
    ProcessRegistry.unregister({:agent_control, agent_id})
  end

  defp unregister_legacy_session_key(_key), do: :ok

  @spec send_stream_reply(GRPC.Server.Stream.t(), struct()) ::
          {:ok, GRPC.Server.Stream.t()} | {:error, term()}
  defp send_stream_reply(stream, response) do
    {:ok, GRPC.Server.send_reply(stream, response)}
  rescue
    error ->
      {:error, error}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp broadcast_ack(ack, state) do
    command_meta = Map.get(state.commands, ack.command_id, %{})

    data =
      command_meta
      |> Map.merge(base_command_metadata(state))
      |> Map.merge(%{
        command_id: ack.command_id,
        command_type: ack.command_type,
        message: ack.message,
        timestamp: ack.timestamp
      })

    PubSub.broadcast_ack(data)
  end

  defp broadcast_progress(progress, state) do
    command_meta = Map.get(state.commands, progress.command_id, %{})
    payload = decode_payload(progress.payload_json)

    data =
      command_meta
      |> Map.merge(base_command_metadata(state))
      |> Map.merge(%{
        command_id: progress.command_id,
        command_type: progress.command_type,
        progress_percent: progress.progress_percent,
        message: progress.message,
        timestamp: progress.timestamp,
        payload: payload
      })

    PubSub.broadcast_progress(data)
  end

  defp broadcast_result(result, command_meta, state) do
    payload = decode_payload(result.payload_json)

    log_command_result(state, result, payload)

    data =
      command_meta
      |> Map.merge(base_command_metadata(state))
      |> Map.merge(%{
        command_id: result.command_id,
        command_type: result.command_type,
        success: result.success,
        message: result.message,
        timestamp: result.timestamp,
        payload: payload
      })

    PubSub.broadcast_result(data)
  end

  defp base_command_metadata(state) do
    %{
      agent_id: state.agent_id,
      partition_id: state.partition_id,
      gateway_node: state.gateway_node
    }
  end

  defp decode_payload(nil), do: nil
  defp decode_payload(<<>>), do: nil

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  defp log_command_dispatch(state, command) do
    Logger.info(
      "Dispatching command to agent #{state.agent_id}: #{command.command_type} (#{command.command_id})"
    )
  end

  defp log_command_ack(state, ack) do
    Logger.info(
      "Command ack from agent #{state.agent_id}: #{ack.command_type} (#{ack.command_id}) #{ack.message}"
    )
  end

  defp log_command_progress(state, progress) do
    Logger.info(
      "Command progress from agent #{state.agent_id}: #{progress.command_type} (#{progress.command_id}) " <>
        "#{progress.progress_percent}% #{progress.message}"
    )
  end

  defp log_command_result(state, result, payload) do
    payload_summary =
      case payload do
        %{} = data ->
          %{
            keys: Map.keys(data),
            sweep_group_id: Map.get(data, "sweep_group_id"),
            discovery_id: Map.get(data, "discovery_id")
          }

        _ ->
          payload
      end

    Logger.info(
      "Command result from agent #{state.agent_id}: #{result.command_type} (#{result.command_id}) " <>
        "success=#{result.success} message=#{result.message} payload=#{inspect(payload_summary)}"
    )
  end

  defp track_command(state, command, context) do
    command_meta =
      context
      |> normalize_context()
      |> Map.put_new(:command_id, command.command_id)
      |> Map.put_new(:command_type, command.command_type)
      |> Map.put_new(:agent_id, state.agent_id)
      |> Map.put_new(:partition_id, state.partition_id)
      |> Map.put_new(:sent_at, DateTime.utc_now())

    %{state | commands: Map.put(state.commands, command.command_id, command_meta)}
  end

  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(_), do: %{}
end
