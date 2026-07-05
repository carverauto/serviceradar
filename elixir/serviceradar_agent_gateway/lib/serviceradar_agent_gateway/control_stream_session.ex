defmodule ServiceRadarAgentGateway.ControlStreamSession do
  @moduledoc """
  Tracks an agent control stream and routes command/config messages.
  """

  use GenServer

  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.Edge.ProxmoxConsolePubSub
  alias ServiceRadar.Edge.RemoteAccessFileTransfers
  alias ServiceRadar.Edge.RemoteAccessPubSub
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadarAgentGateway.ConfigSyncForwarder

  require Logger

  @max_command_result_payload_bytes 64 * 1024

  @type state :: %{
          stream: GRPC.Server.Stream.t(),
          agent_id: String.t() | nil,
          partition_id: String.t() | nil,
          registered_identity: map() | nil,
          capabilities: [String.t()],
          commands: %{optional(String.t()) => map()},
          registry_key: term() | nil,
          gateway_node: String.t(),
          last_pushed_config_version: String.t() | nil,
          last_synced_config_version: String.t() | nil
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def register(pid, agent_id, partition_id, capabilities, identity_context \\ nil) do
    GenServer.call(pid, {:register, agent_id, partition_id, capabilities, identity_context})
  end

  def handle_message(pid, %Monitoring.ControlStreamRequest{} = message, identity_context \\ nil) do
    GenServer.cast(pid, {:message, message, identity_context})
  end

  def send_command(pid, %Monitoring.CommandRequest{} = command, context \\ %{}) do
    GenServer.call(pid, {:send_command, command, context})
  end

  def push_config(pid, %Monitoring.AgentConfigResponse{} = config) do
    GenServer.call(pid, {:push_config, config})
  end

  def send_console_frame(pid, frame) when is_map(frame) do
    GenServer.call(pid, {:send_console_frame, frame})
  end

  @impl true
  def init(opts) do
    stream = Keyword.fetch!(opts, :stream)

    {:ok,
     %{
       stream: stream,
       agent_id: nil,
       partition_id: nil,
       registered_identity: nil,
       capabilities: [],
       commands: %{},
       registry_key: nil,
       gateway_node: Atom.to_string(node()),
       last_pushed_config_version: nil,
       last_synced_config_version: nil
     }}
  end

  @impl true
  def handle_call({:register, agent_id, partition_id, capabilities, identity_context}, _from, state) do
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
         registered_identity: normalize_identity_context(identity_context, agent_id, partition_id),
         capabilities: capabilities,
         registry_key: key
     }}
  end

  def handle_call({:send_command, command, context}, _from, state) do
    response = %Monitoring.ControlStreamResponse{payload: {:command, command}}

    case send_stream_reply(state.stream, response) do
      {:ok, stream} ->
        log_command_dispatch(state, command)

        {:reply, {:ok, command.command_id}, track_command(%{state | stream: stream}, command, context)}

      {:error, reason} ->
        Logger.warning("Failed to dispatch command to agent #{state.agent_id}: #{inspect(reason)}")

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:push_config, config}, _from, state) do
    response = %Monitoring.ControlStreamResponse{payload: {:config, config}}

    case send_stream_reply(state.stream, response) do
      {:ok, stream} ->
        {:reply, :ok, forward_config_push(%{state | stream: stream}, config)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_console_frame, frame}, _from, state) do
    case normalize_console_frame(frame) do
      {:ok, frame} ->
        response = %Monitoring.ControlStreamResponse{payload: {:console_frame, frame}}

        case send_stream_reply(state.stream, response) do
          {:ok, stream} ->
            {:reply, :ok, %{state | stream: stream}}

          {:error, reason} ->
            Logger.warning("Failed to send Proxmox console frame to agent #{state.agent_id}: #{inspect(reason)}")

            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:message, %Monitoring.ControlStreamRequest{} = message, identity_context}, state) do
    case verify_message_identity(state, identity_context) do
      :ok ->
        handle_verified_message(message, state)

      {:error, reason} ->
        audit_message_identity_rejection(reason, state, identity_context)
        {:stop, :normal, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    if state.agent_id do
      Logger.info(
        "Control stream session ended: agent_id=#{state.agent_id}, reason=#{inspect(reason)}, pending_commands=#{map_size(state.commands)}"
      )
    end

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

  defp refresh_control_registration(%{agent_id: nil} = state), do: {:noreply, state}

  defp refresh_control_registration(state) do
    key = state.registry_key || {:agent_control, state.agent_id, node()}

    metadata = %{
      agent_id: state.agent_id,
      partition_id: state.partition_id,
      capabilities: state.capabilities,
      connected_at: DateTime.utc_now(),
      gateway_node: state.gateway_node
    }

    :ok = register_session(key, metadata)
    Logger.debug("Refreshed control stream registration for agent #{state.agent_id}")
    {:noreply, %{state | registry_key: key}}
  end

  defp handle_verified_message(%Monitoring.ControlStreamRequest{} = message, state) do
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
        result = enforce_command_result_payload_cap(result)
        broadcast_result(result, command_meta, state)
        {:noreply, %{state | commands: commands}}

      {:config_ack, ack} ->
        Logger.debug(
          "Agent config ack: agent_id=#{state.agent_id} version=#{ack.config_version} " <>
            "sections=#{length(ack.section_statuses)}"
        )

        {:noreply, forward_config_ack(state, ack)}

      {:console_frame, frame} ->
        broadcast_console_frame(frame, state)
        {:noreply, state}

      {:hello, hello} ->
        {:noreply, state} = refresh_control_registration(state)
        {:noreply, forward_reported_config_version(state, hello)}

      nil ->
        {:noreply, state}
    end
  end

  defp normalize_identity_context(nil, _agent_id, _partition_id), do: nil

  defp normalize_identity_context(identity_context, agent_id, partition_id) when is_map(identity_context) do
    %{
      component_id: Map.get(identity_context, :component_id, agent_id),
      partition_id: Map.get(identity_context, :partition_id, partition_id),
      component_type: Map.get(identity_context, :component_type),
      cert_fingerprint_sha256: Map.get(identity_context, :cert_fingerprint_sha256)
    }
  end

  defp verify_message_identity(%{registered_identity: nil}, _identity_context), do: :ok
  defp verify_message_identity(_state, nil), do: {:error, :missing_identity_context}

  defp verify_message_identity(%{registered_identity: registered}, identity_context) when is_map(identity_context) do
    identity_context = normalize_identity_context(identity_context, nil, nil)

    cond do
      identity_context.component_id != registered.component_id ->
        {:error, :component_id_mismatch}

      identity_context.partition_id != registered.partition_id ->
        {:error, :partition_id_mismatch}

      identity_context.component_type != registered.component_type ->
        {:error, :component_type_mismatch}

      identity_context.cert_fingerprint_sha256 != registered.cert_fingerprint_sha256 ->
        {:error, :certificate_fingerprint_mismatch}

      true ->
        :ok
    end
  end

  defp verify_message_identity(_state, _identity_context), do: {:error, :invalid_identity_context}

  defp audit_message_identity_rejection(reason, state, identity_context) do
    metadata = %{
      reason: reason,
      agent_id: state.agent_id,
      partition_id: state.partition_id,
      identity_component_id: map_identity_value(identity_context, :component_id),
      identity_partition_id: map_identity_value(identity_context, :partition_id),
      identity_component_type: map_identity_value(identity_context, :component_type)
    }

    :telemetry.execute(
      [:serviceradar, :control_stream, :message, :rejected],
      %{count: 1},
      metadata
    )

    Logger.warning("Rejected control stream message identity", Map.to_list(metadata))
  end

  defp map_identity_value(identity_context, key) when is_map(identity_context), do: Map.get(identity_context, key)
  defp map_identity_value(_identity_context, _key), do: nil

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

  defp broadcast_console_frame(%Monitoring.ConsoleFrame{} = frame, state) do
    session_id = to_string(frame.session_id || "")

    if session_id != "" and registered_agent?(state) do
      frame_payload = %{
        session_id: session_id,
        frame_type: frame.frame_type,
        data: frame.data,
        cols: frame.cols,
        rows: frame.rows,
        reason: frame.reason,
        timestamp: frame.timestamp,
        seq: frame.seq,
        payload_sha256: frame.payload_sha256,
        signature: frame.signature,
        agent_id: state.agent_id,
        partition_id: state.partition_id,
        gateway_node: state.gateway_node
      }

      ProxmoxConsolePubSub.broadcast_frame(session_id, frame_payload)
      RemoteAccessPubSub.broadcast_frame(session_id, frame_payload)
      _ = RemoteAccessFileTransfers.handle_agent_frame(frame_payload)
    end
  end

  # Persist the acked version + per-section statuses on core (wedge detection).
  # Fire-and-forget: a core outage must not stall the agent's control stream.
  defp forward_config_ack(state, ack) do
    if registered_agent?(state) do
      agent_id = state.agent_id
      {:ok, _pid} = Task.start(fn -> ConfigSyncForwarder.record_config_ack(agent_id, ack) end)

      %{state | last_synced_config_version: ack.config_version}
    else
      state
    end
  end

  # A heartbeat hello reports the agent's committed config version (set only after a
  # fully-successful apply) — forward it as a whole-version ack so versions applied
  # via the poll path (which never stream-acks) do not read as unacknowledged.
  # Debounced on the version so the 60s heartbeat does not spam core.
  defp forward_reported_config_version(state, %Monitoring.ControlStreamHello{} = hello) do
    version = to_string(hello.config_version || "")

    if registered_agent?(state) and version != "" and version != state.last_synced_config_version do
      agent_id = state.agent_id
      {:ok, _pid} = Task.start(fn -> ConfigSyncForwarder.record_reported_version(agent_id, version) end)

      %{state | last_synced_config_version: version}
    else
      state
    end
  end

  defp forward_reported_config_version(state, _hello), do: state

  # Record the pushed config version on core: it anchors the no-ack wedge window
  # (an agent that never acks a pushed version becomes config-unhealthy). Debounced
  # on the version; core additionally keeps the FIRST push timestamp of a version.
  defp forward_config_push(state, %Monitoring.AgentConfigResponse{} = config) do
    version = to_string(config.config_version || "")

    if registered_agent?(state) and version != "" and not config.not_modified and
         version != state.last_pushed_config_version do
      agent_id = state.agent_id
      {:ok, _pid} = Task.start(fn -> ConfigSyncForwarder.record_config_push(agent_id, version) end)

      %{state | last_pushed_config_version: version}
    else
      state
    end
  end

  defp forward_config_push(state, _config), do: state

  defp registered_agent?(state) do
    is_binary(state.agent_id) and String.trim(state.agent_id) != ""
  end

  defp normalize_console_frame(%Monitoring.ConsoleFrame{} = frame), do: {:ok, frame}

  defp normalize_console_frame(frame) when is_map(frame) do
    session_id = frame |> map_value(:session_id) |> to_string()
    frame_type = frame |> map_value(:frame_type) |> to_string()

    if session_id == "" or frame_type == "" do
      {:error, :invalid_console_frame}
    else
      {:ok,
       %Monitoring.ConsoleFrame{
         session_id: session_id,
         frame_type: frame_type,
         data: map_value(frame, :data) || "",
         cols: uint32(map_value(frame, :cols)),
         rows: uint32(map_value(frame, :rows)),
         reason: map_value(frame, :reason) || "",
         timestamp: timestamp(map_value(frame, :timestamp)),
         seq: uint64(map_value(frame, :seq)),
         payload_sha256: map_value(frame, :payload_sha256) || "",
         signature: map_value(frame, :signature) || ""
       }}
    end
  end

  defp normalize_console_frame(_frame), do: {:error, :invalid_console_frame}

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp uint32(value) when is_integer(value) and value > 0, do: min(value, 65_535)
  defp uint32(_value), do: 0

  defp uint64(value) when is_integer(value) and value > 0, do: value
  defp uint64(_value), do: 0

  defp timestamp(value) when is_integer(value) and value > 0, do: value
  defp timestamp(_value), do: System.system_time(:second)

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

  defp enforce_command_result_payload_cap(%Monitoring.CommandResult{} = result) do
    if byte_size(result.payload_json || <<>>) > @max_command_result_payload_bytes do
      %{
        result
        | success: false,
          message: "command result payload exceeded byte cap",
          payload_json: Jason.encode!(%{"error" => "payload_too_large"})
      }
    else
      result
    end
  end

  defp log_command_dispatch(state, command) do
    Logger.info("Dispatching command to agent #{state.agent_id}: #{command.command_type} (#{command.command_id})")
  end

  defp log_command_ack(state, ack) do
    Logger.info("Command ack from agent #{state.agent_id}: #{ack.command_type} (#{ack.command_id}) #{ack.message}")
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
