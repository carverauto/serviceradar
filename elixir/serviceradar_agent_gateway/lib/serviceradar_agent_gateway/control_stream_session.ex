defmodule ServiceRadarAgentGateway.ControlStreamSession do
  @moduledoc """
  Tracks an agent control stream and routes command/config messages.
  """

  use GenServer

  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.Automation.Ansible.AutomationResultSanitizer
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Edge.ProxmoxConsolePubSub
  alias ServiceRadar.Edge.RemoteAccessFileTransfers
  alias ServiceRadar.Edge.RemoteAccessPubSub
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.ConfigSyncForwarder
  alias ServiceRadarAgentGateway.ControlStreamTelemetry

  require Logger

  @max_command_result_payload_bytes 64 * 1024
  # Catalog and bounded event projections can legitimately exceed the generic
  # command cap. They are still constrained to a small gRPC-safe envelope and
  # pass through the schema-specific AWX sanitizer before broadcast.
  @max_awx_command_result_payload_bytes 3 * 1024 * 1024
  @config_push_retry_initial_ms 100
  @config_push_retry_max_ms 5_000

  @type state :: %{
          stream: GRPC.Server.Stream.t(),
          agent_id: String.t() | nil,
          partition_id: String.t() | nil,
          registered_identity: map() | nil,
          capabilities: [String.t()],
          config_version: String.t() | nil,
          applied_plugin_assignments: [map()],
          commands: %{optional(String.t()) => map()},
          registry_key: term() | nil,
          gateway_node: String.t(),
          last_pushed_config_version: String.t() | nil,
          last_synced_config_version: String.t() | nil,
          pending_config_version: String.t() | nil,
          pending_config_acknowledged: boolean(),
          pending_config_persisted: boolean(),
          config_push_sync: map() | nil
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def register(pid, agent_id, partition_id, capabilities, identity_context \\ nil, control_hello \\ nil) do
    GenServer.call(
      pid,
      {:register, agent_id, partition_id, capabilities, identity_context, control_hello}
    )
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

  def send_console_frame(pid, frame, expected_control_evidence) when is_map(frame) do
    GenServer.call(pid, {:send_console_frame, frame, expected_control_evidence})
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
       config_version: nil,
       applied_plugin_assignments: [],
       commands: %{},
       registry_key: nil,
       gateway_node: Atom.to_string(node()),
       last_pushed_config_version: nil,
       last_synced_config_version: nil,
       pending_config_version: nil,
       pending_config_acknowledged: false,
       pending_config_persisted: false,
       config_push_sync: nil
     }}
  end

  @impl true
  def handle_call({:register, agent_id, partition_id, capabilities, identity_context, control_hello}, _from, state) do
    with {:ok, {agent_id, partition_id}} <- canonical_control_principal(agent_id, partition_id),
         :ok <- validate_registration_identity(identity_context, agent_id, partition_id) do
      state =
        state
        |> Map.put(:agent_id, agent_id)
        |> Map.put(:partition_id, partition_id)
        |> Map.put(
          :registered_identity,
          normalize_identity_context(identity_context, agent_id, partition_id)
        )
        |> Map.put(:capabilities, normalize_capabilities(capabilities))
        |> update_control_evidence(control_hello)

      metadata = control_registration_metadata(state)
      key = control_registry_key(partition_id, agent_id)

      case register_session(key, metadata) do
        :ok ->
          state = state |> Map.put(:registry_key, key) |> sync_delivery_capabilities()
          state = forward_reported_config_version(state, control_hello)
          ControlStreamTelemetry.connected(self(), %{gateway_id: Config.gateway_id(), partition_id: partition_id})
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_command, command, context}, _from, state) do
    response = %Monitoring.ControlStreamResponse{payload: {:command, command}}

    case send_stream_reply(state.stream, response) do
      {:ok, stream} ->
        log_command_dispatch(state, command)

        {:reply, {:ok, command.command_id}, track_command(%{state | stream: stream}, command, context)}

      {:error, reason} ->
        Logger.warning(
          "Failed to dispatch command to agent",
          [agent_id: safe_log_identifier(state.agent_id)] ++
            SafeFailureEvidence.log_metadata(reason)
        )

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:push_config, config}, _from, state) do
    case validate_config_push(config) do
      :ok ->
        response = %Monitoring.ControlStreamResponse{payload: {:config, config}}

        previous_pending = pending_config_state(state)
        state = mark_config_push_pending(state, config)
        {:noreply, state} = refresh_control_registration(state)

        case send_stream_reply(state.stream, response) do
          {:ok, stream} ->
            state = forward_config_push(%{state | stream: stream}, config)
            {:noreply, state} = refresh_control_registration(state)
            {:reply, :ok, state}

          {:error, reason} ->
            state = restore_pending_config_state(state, previous_pending)
            {:noreply, state} = refresh_control_registration(state)
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_console_frame, frame}, _from, state) do
    dispatch_console_frame(frame, nil, state)
  end

  def handle_call({:send_console_frame, frame, expected_control_evidence}, _from, state) do
    dispatch_console_frame(frame, expected_control_evidence, state)
  end

  defp dispatch_console_frame(frame, expected_control_evidence, state) do
    case normalize_console_frame(frame) do
      {:ok, frame} ->
        dispatch_verified_console_frame(frame, expected_control_evidence, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp dispatch_verified_console_frame(frame, expected_control_evidence, state) do
    case verify_expected_control_evidence(state, expected_control_evidence) do
      :ok -> send_console_frame_reply(frame, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp send_console_frame_reply(frame, state) do
    response = %Monitoring.ControlStreamResponse{payload: {:console_frame, frame}}

    case send_stream_reply(state.stream, response) do
      {:ok, stream} ->
        {:reply, :ok, %{state | stream: stream}}

      {:error, reason} ->
        Logger.warning(
          "Failed to send Proxmox console frame to agent",
          [agent_id: safe_log_identifier(state.agent_id)] ++
            SafeFailureEvidence.log_metadata(reason)
        )

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
  def handle_info({:retry_config_push_sync, version, attempt}, state) do
    case state.config_push_sync do
      %{version: ^version, attempt: ^attempt} ->
        state = persist_config_push(state, version, attempt)
        {:noreply, state} = refresh_control_registration(state)
        {:noreply, state}

      _stale_or_completed ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    if state.agent_id do
      Logger.info(
        "Control stream session ended",
        [
          agent_id: safe_log_identifier(state.agent_id),
          pending_commands: map_size(state.commands)
        ] ++ SafeFailureEvidence.log_metadata(reason)
      )
    end

    _ = sync_delivery_capabilities(state)

    if state.registry_key && Process.whereis(ProcessRegistry.registry_name()) do
      ProcessRegistry.unregister(state.registry_key)
    end

    :ok
  end

  defp register_session(key, metadata) do
    unregister_legacy_session_keys(key)

    case ProcessRegistry.register(key, metadata) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        update_existing_session_registration(key, metadata)

      {:error, {:already_registered, pid}} ->
        {:error, {:control_session_already_registered, pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_existing_session_registration(key, metadata) do
    case ProcessRegistry.update_value(key, fn _current -> metadata end) do
      :error -> {:error, :control_session_registration_lost}
      {_new, _old} -> :ok
    end
  end

  defp refresh_control_registration(%{agent_id: nil} = state), do: {:noreply, state}

  defp refresh_control_registration(state) do
    if Process.whereis(ProcessRegistry.registry_name()) do
      refresh_available_control_registration(state)
    else
      Logger.warning(
        "Skipped control stream registration refresh because registry is unavailable",
        agent_id: safe_log_identifier(state.agent_id)
      )

      {:noreply, state}
    end
  end

  defp refresh_available_control_registration(state) do
    key = state.registry_key || control_registry_key(state.partition_id, state.agent_id)

    metadata = control_registration_metadata(state)

    :ok = register_session(key, metadata)

    Logger.debug("Refreshed control stream registration",
      agent_id: safe_log_identifier(state.agent_id)
    )

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
        result = enforce_command_result_payload_cap(result, command_meta)
        broadcast_result(result, command_meta, state)
        {:noreply, %{state | commands: commands}}

      {:config_ack, ack} ->
        Logger.debug("Agent config ack",
          agent_id: safe_log_identifier(state.agent_id),
          config_version: safe_log_identifier(ack.config_version),
          section_count: length(ack.section_statuses)
        )

        state =
          state
          |> update_control_evidence(ack)
          |> acknowledge_pending_config(ack.config_version)

        {:noreply, state} = refresh_control_registration(state)
        {:noreply, forward_config_ack(state, ack)}

      {:console_frame, frame} ->
        broadcast_console_frame(frame, state)
        {:noreply, state}

      {:hello, hello} ->
        state =
          state
          |> update_control_evidence(hello)
          |> acknowledge_pending_config(hello.config_version)

        state = sync_delivery_capabilities(state)
        {:noreply, state} = refresh_control_registration(state)
        {:noreply, forward_reported_config_version(state, hello)}

      nil ->
        {:noreply, state}
    end
  end

  defp control_registration_metadata(state) do
    %{
      agent_id: state.agent_id,
      partition_id: state.partition_id,
      capabilities: state.capabilities,
      config_version: state.config_version,
      pending_config_version: state.pending_config_version,
      applied_plugin_assignments: state.applied_plugin_assignments,
      connected_at: DateTime.utc_now(),
      gateway_node: state.gateway_node
    }
  end

  defp sync_delivery_capabilities(%{agent_id: agent_id, partition_id: partition_id} = state)
       when is_binary(agent_id) and is_binary(partition_id) do
    _ = AgentRegistryProxy.sync_delivery_capabilities(partition_id, agent_id, state.capabilities)
    state
  end

  defp sync_delivery_capabilities(state), do: state

  # This comparison and the stream write execute in one GenServer call. A
  # config ACK/push or reconnect therefore cannot replace the authenticated
  # evidence between authorization and dispatch.
  defp verify_expected_control_evidence(_state, nil), do: :ok

  defp verify_expected_control_evidence(state, expected) when is_map(expected) do
    current = %{
      control_session_pid: self(),
      agent_id: state.agent_id,
      gateway_node: state.gateway_node,
      capabilities: state.capabilities,
      config_version: state.config_version,
      pending_config_version: state.pending_config_version,
      applied_plugin_assignments: state.applied_plugin_assignments
    }

    expected_snapshot = %{
      control_session_pid: map_value(expected, :control_session_pid),
      agent_id: map_value(expected, :agent_id),
      gateway_node: map_value(expected, :gateway_node),
      capabilities: map_value(expected, :capabilities),
      config_version: map_value(expected, :config_version),
      pending_config_version: map_value(expected, :pending_config_version),
      applied_plugin_assignments: map_value(expected, :applied_plugin_assignments)
    }

    cond do
      state.pending_config_version != nil ->
        {:error, :console_config_transition_pending}

      current != expected_snapshot ->
        {:error, :console_control_session_changed}

      true ->
        :ok
    end
  end

  defp verify_expected_control_evidence(_state, _expected), do: {:error, :console_control_evidence_unavailable}

  defp update_control_evidence(state, %Monitoring.ControlStreamHello{} = hello) do
    %{
      state
      | capabilities: normalize_capabilities(hello.capabilities),
        config_version: normalize_config_version(hello.config_version),
        applied_plugin_assignments: normalize_applied_plugin_assignments(hello.applied_plugin_assignments)
    }
  end

  defp update_control_evidence(state, %Monitoring.ConfigAck{} = ack) do
    %{
      state
      | config_version: normalize_config_version(ack.config_version),
        applied_plugin_assignments: normalize_applied_plugin_assignments(ack.applied_plugin_assignments)
    }
  end

  defp update_control_evidence(state, _message), do: state

  defp normalize_config_version(version) when is_binary(version) do
    case String.trim(version) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_config_version(_version), do: nil

  defp normalize_capabilities(capabilities) do
    capabilities
    |> List.wrap()
    |> Enum.flat_map(fn
      capability when is_binary(capability) ->
        case String.trim(capability) do
          "" -> []
          value -> [value]
        end

      _capability ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def normalize_applied_plugin_assignments(assignments) when is_list(assignments) do
    if length(assignments) > 1_024 do
      []
    else
      assignments
      |> Enum.reduce_while({:ok, %{}}, &reduce_plugin_assignment/2)
      |> case do
        {:ok, normalized} ->
          normalized
          |> Map.values()
          |> Enum.sort_by(&{&1.assignment_id, &1.plugin_id})

        :error ->
          []
      end
    end
  end

  def normalize_applied_plugin_assignments(_assignments), do: []

  defp reduce_plugin_assignment(assignment, {:ok, normalized}) do
    with {:ok, proof} <- normalize_plugin_assignment_proof(assignment),
         key = {proof.assignment_id, proof.plugin_id},
         false <- Map.has_key?(normalized, key) do
      {:cont, {:ok, Map.put(normalized, key, proof)}}
    else
      _ -> {:halt, :error}
    end
  end

  defp normalize_plugin_assignment_proof(%Monitoring.PluginAssignmentPolicyAck{} = proof) do
    assignment_id = trimmed_string(proof.assignment_id)
    plugin_id = trimmed_string(proof.plugin_id)
    fingerprint = trimmed_string(proof.assignment_policy_fingerprint)

    if assignment_id != nil and plugin_id in ["proxmox-inventory", "proxmox-console"] and
         is_integer(proof.assignment_policy_version) and proof.assignment_policy_version > 0 and
         valid_policy_fingerprint?(fingerprint) do
      {:ok,
       %{
         assignment_id: assignment_id,
         plugin_id: plugin_id,
         assignment_policy_version: proof.assignment_policy_version,
         assignment_policy_fingerprint: fingerprint
       }}
    else
      {:error, :invalid_plugin_assignment_policy_ack}
    end
  end

  defp normalize_plugin_assignment_proof(_proof), do: {:error, :invalid_plugin_assignment_policy_ack}

  defp trimmed_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed_string(_value), do: nil

  defp valid_policy_fingerprint?(fingerprint) when is_binary(fingerprint),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint)

  defp valid_policy_fingerprint?(_fingerprint), do: false

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

  defp unregister_legacy_session_keys({:agent_control, _partition_id, agent_id, _node}) do
    # Horde.Registry.unregister/2 only removes keys owned by the calling
    # process. These calls therefore clean up this session's rolling-upgrade
    # aliases without being able to evict another authenticated principal.
    ProcessRegistry.unregister({:agent_control, agent_id, node()})
    ProcessRegistry.unregister({:agent_control, agent_id})
  end

  defp unregister_legacy_session_keys(_key), do: :ok

  defp control_registry_key(partition_id, agent_id), do: {:agent_control, partition_id, agent_id, node()}

  defp canonical_control_principal(agent_id, partition_id) do
    with agent_id when is_binary(agent_id) <- trimmed_string(agent_id),
         partition_id when is_binary(partition_id) <- trimmed_string(partition_id) do
      {:ok, {agent_id, partition_id}}
    else
      _ -> {:error, :invalid_control_principal}
    end
  end

  defp validate_registration_identity(nil, _agent_id, _partition_id), do: :ok

  defp validate_registration_identity(identity_context, agent_id, partition_id) when is_map(identity_context) do
    identity = normalize_identity_context(identity_context, nil, nil)

    cond do
      identity.component_id != agent_id -> {:error, :component_id_mismatch}
      identity.partition_id != partition_id -> {:error, :partition_id_mismatch}
      true -> :ok
    end
  end

  defp validate_registration_identity(_identity_context, _agent_id, _partition_id),
    do: {:error, :invalid_identity_context}

  @spec send_stream_reply(GRPC.Server.Stream.t(), struct()) ::
          {:ok, GRPC.Server.Stream.t()} | {:error, term()}
  defp send_stream_reply(stream, response) do
    sender =
      Application.get_env(
        :serviceradar_agent_gateway,
        :control_stream_reply,
        &GRPC.Server.send_reply/2
      )

    {:ok, sender.(stream, response)}
  rescue
    error ->
      {:error, error}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp broadcast_ack(ack, state) do
    command_meta = Map.get(state.commands, ack.command_id, %{})

    case verified_command_type(command_meta, ack.command_type) do
      {:ok, command_type} ->
        data =
          command_meta
          |> Map.merge(base_command_metadata(state))
          |> Map.merge(%{
            command_id: ack.command_id,
            command_type: command_type,
            message: ack.message,
            timestamp: ack.timestamp
          })

        data |> AutomationResultSanitizer.sanitize_ack() |> PubSub.broadcast_ack()

      {:error, expected_type} ->
        log_command_type_mismatch(state, ack.command_id, expected_type, ack.command_type, "ack")
    end
  end

  defp broadcast_progress(progress, state) do
    command_meta = Map.get(state.commands, progress.command_id, %{})
    payload = decode_payload(progress.payload_json)

    case verified_command_type(command_meta, progress.command_type) do
      {:ok, command_type} ->
        data =
          command_meta
          |> Map.merge(base_command_metadata(state))
          |> Map.merge(%{
            command_id: progress.command_id,
            command_type: command_type,
            progress_percent: progress.progress_percent,
            message: progress.message,
            timestamp: progress.timestamp,
            payload: payload
          })

        data |> AutomationResultSanitizer.sanitize_progress() |> PubSub.broadcast_progress()

      {:error, expected_type} ->
        log_command_type_mismatch(
          state,
          progress.command_id,
          expected_type,
          progress.command_type,
          "progress"
        )
    end
  end

  defp broadcast_result(result, command_meta, state) do
    data = result_data(result, command_meta, state)

    safe_data = AutomationResultSanitizer.sanitize(data)
    log_command_result(state, safe_data)
    PubSub.broadcast_result(safe_data)
  end

  defp result_data(result, command_meta, state) do
    case verified_command_type(command_meta, result.command_type) do
      {:ok, command_type} ->
        command_meta
        |> Map.merge(base_command_metadata(state))
        |> Map.merge(%{
          command_id: result.command_id,
          command_type: command_type,
          success: result.success,
          message: result.message,
          timestamp: result.timestamp,
          payload: decode_payload(result.payload_json)
        })

      {:error, expected_type} ->
        log_command_type_mismatch(
          state,
          result.command_id,
          expected_type,
          result.command_type,
          "result"
        )

        command_meta
        |> Map.merge(base_command_metadata(state))
        |> Map.merge(%{
          command_id: result.command_id,
          command_type: expected_type,
          success: false,
          message: "command type mismatch",
          failure_reason: "command_type_mismatch",
          timestamp: result.timestamp,
          payload: %{}
        })
    end
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

      {:ok, _pid} =
        Task.start(fn -> ConfigSyncForwarder.record_reported_version(agent_id, version) end)

      %{state | last_synced_config_version: version}
    else
      state
    end
  end

  defp forward_reported_config_version(state, _hello), do: state

  # Record the pushed config version on core: it anchors the no-ack wedge window.
  # Unlike a detached fire-and-forget task, the live session owns retry state and
  # keeps the registry marked pending until both persistence and an exact agent
  # acknowledgement have completed.
  defp forward_config_push(state, %Monitoring.AgentConfigResponse{} = config) do
    version = normalize_config_version(config.config_version)

    if registered_agent?(state) and version != nil and not config.not_modified and
         version != state.last_pushed_config_version do
      state = %{
        state
        | last_pushed_config_version: version,
          config_push_sync: %{version: version, attempt: 0}
      }

      persist_config_push(state, version, 0)
    else
      state
    end
  end

  # A full config without an authoritative version cannot be represented in
  # live pending evidence or correlated with a later ACK. Never put such a
  # transition on the authenticated stream; otherwise a console open could be
  # authorized against the previous policy while the agent applies unversioned
  # assignments.
  defp validate_config_push(%Monitoring.AgentConfigResponse{not_modified: false} = config) do
    if normalize_config_version(config.config_version) == nil do
      {:error, :invalid_config_version}
    else
      :ok
    end
  end

  defp validate_config_push(%Monitoring.AgentConfigResponse{}), do: :ok

  defp persist_config_push(state, version, attempt) do
    case ConfigSyncForwarder.record_config_push(state.agent_id, version) do
      :ok ->
        state
        |> Map.put(:config_push_sync, nil)
        |> mark_pending_config_persisted(version)

      {:error, _reason} ->
        next_attempt = attempt + 1
        delay = config_push_retry_delay(next_attempt)
        Process.send_after(self(), {:retry_config_push_sync, version, next_attempt}, delay)
        %{state | config_push_sync: %{version: version, attempt: next_attempt}}
    end
  end

  defp config_push_retry_delay(attempt) do
    multiplier = Integer.pow(2, min(max(attempt - 1, 0), 10))
    min(@config_push_retry_initial_ms * multiplier, @config_push_retry_max_ms)
  end

  defp mark_config_push_pending(state, %Monitoring.AgentConfigResponse{} = config) do
    version = normalize_config_version(config.config_version)

    cond do
      config.not_modified or version == nil ->
        state

      state.pending_config_version == version ->
        state

      true ->
        %{
          state
          | pending_config_version: version,
            pending_config_acknowledged: false,
            pending_config_persisted: false
        }
    end
  end

  defp acknowledge_pending_config(state, version) do
    version = normalize_config_version(version)

    if version != nil and version == state.pending_config_version do
      state
      |> Map.put(:pending_config_acknowledged, true)
      |> maybe_clear_pending_config()
    else
      state
    end
  end

  defp mark_pending_config_persisted(state, version) do
    if version == state.pending_config_version do
      state
      |> Map.put(:pending_config_persisted, true)
      |> maybe_clear_pending_config()
    else
      state
    end
  end

  defp maybe_clear_pending_config(%{pending_config_acknowledged: true, pending_config_persisted: true} = state) do
    %{
      state
      | pending_config_version: nil,
        pending_config_acknowledged: false,
        pending_config_persisted: false
    }
  end

  defp maybe_clear_pending_config(state), do: state

  defp pending_config_state(state) do
    Map.take(state, [
      :pending_config_version,
      :pending_config_acknowledged,
      :pending_config_persisted,
      :config_push_sync
    ])
  end

  defp restore_pending_config_state(state, previous_pending) do
    Map.merge(state, previous_pending)
  end

  defp registered_agent?(state) do
    is_binary(state.agent_id) and String.trim(state.agent_id) != ""
  end

  @doc false
  def normalize_console_frame(%Monitoring.ConsoleFrame{} = frame), do: {:ok, frame}

  def normalize_console_frame(frame) when is_map(frame) do
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
         signature: map_value(frame, :signature) || "",
         assignment_policy_version: uint64(map_value(frame, :assignment_policy_version)),
         assignment_policy_fingerprint: map_value(frame, :assignment_policy_fingerprint) || ""
       }}
    end
  end

  def normalize_console_frame(_frame), do: {:error, :invalid_console_frame}

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

  defp enforce_command_result_payload_cap(%Monitoring.CommandResult{} = result, command_meta) do
    expected_type = Map.get(command_meta, :command_type) || Map.get(command_meta, "command_type")

    cap =
      if AutomationResultSanitizer.protected_command?(expected_type),
        do: @max_awx_command_result_payload_bytes,
        else: @max_command_result_payload_bytes

    if byte_size(result.payload_json || <<>>) > cap do
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
    Logger.info("Dispatching command to agent",
      agent_id: safe_log_identifier(state.agent_id),
      command_type: safe_log_identifier(command.command_type),
      command_id: safe_log_identifier(command.command_id)
    )
  end

  defp log_command_ack(state, ack) do
    Logger.info("Command ack from agent",
      agent_id: safe_log_identifier(state.agent_id),
      command_type: safe_log_identifier(ack.command_type),
      command_id: safe_log_identifier(ack.command_id)
    )
  end

  defp log_command_progress(state, progress) do
    Logger.info("Command progress from agent",
      agent_id: safe_log_identifier(state.agent_id),
      command_type: safe_log_identifier(progress.command_type),
      command_id: safe_log_identifier(progress.command_id),
      progress_percent: progress.progress_percent
    )
  end

  defp log_command_result(state, data) do
    payload = Map.get(data, :payload)

    Logger.info("Command result from agent",
      agent_id: safe_log_identifier(state.agent_id),
      command_type: safe_log_identifier(Map.get(data, :command_type)),
      command_id: safe_log_identifier(Map.get(data, :command_id)),
      success: Map.get(data, :success) == true,
      payload_field_count: if(is_map(payload), do: map_size(payload), else: 0)
    )
  end

  defp safe_log_identifier(value) when is_binary(value) do
    if byte_size(value) <= 128 and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value),
      do: value,
      else: "invalid"
  end

  defp safe_log_identifier(_value), do: "invalid"

  defp verified_command_type(command_meta, reported_type) do
    expected_type = Map.get(command_meta, :command_type) || Map.get(command_meta, "command_type")

    if is_binary(expected_type) and expected_type != "" and expected_type != reported_type,
      do: {:error, expected_type},
      else: {:ok, expected_type || reported_type}
  end

  defp log_command_type_mismatch(state, command_id, expected_type, reported_type, phase) do
    Logger.warning("Rejected mismatched command status",
      agent_id: safe_log_identifier(state.agent_id),
      command_id: safe_log_identifier(command_id),
      expected_command_type: safe_log_identifier(expected_type),
      reported_command_type: safe_log_identifier(reported_type),
      phase: phase
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
