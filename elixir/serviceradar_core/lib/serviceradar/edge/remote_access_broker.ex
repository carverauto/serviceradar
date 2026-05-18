defmodule ServiceRadar.Edge.RemoteAccessBroker do
  @moduledoc """
  Broker boundary for generic browser-to-agent remote-access byte streams.

  This uses the existing console frame control-stream path while the protobuf
  remains in compatibility mode. Open frames carry a `protocol` field so the Go
  agent can dispatch to protocol-specific adapters such as SSH.
  """

  use GenServer

  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.RemoteAccessFileTransfers
  alias ServiceRadar.Edge.RemoteAccessPubSub
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSessions
  alias ServiceRadar.Events.AuditWriter

  require Logger

  @callback start_link(map() | struct(), pid(), keyword()) :: GenServer.on_start()
  @callback send_input(pid(), binary()) :: :ok | {:error, term()}
  @callback send_application_request(pid(), map()) :: :ok | {:error, term()}
  @callback send_file_transfer_data(pid(), map()) :: :ok | {:error, term()}
  @callback resize(pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  @callback close(pid(), term()) :: :ok

  @default_protocol "ssh"
  @default_credential_mode "user_present"
  @default_terminal_type "xterm-256color"
  @default_ssh_host_key_policy "known_hosts"
  @ssh_host_key_policies ~w(known_hosts trust_on_first_use skip_verify)
  @file_transfer_frame_types ~w(
    file_transfer_progress
    file_transfer_data
    file_transfer_outcome
    file_transfer_error
  )
  @application_frame_types ~w(
    app_response_metadata
    app_data
    app_progress
    app_close
    app_error
    app_outcome
  )
  @tcp_frame_types ~w(
    tcp_data
    tcp_progress
    tcp_close
    tcp_error
    tcp_outcome
  )

  def child_spec({session, owner, opts}) do
    %{
      id: {__MODULE__, session_id(session)},
      start: {__MODULE__, :start_link, [session, owner, opts]},
      restart: :temporary
    }
  end

  def start_link(session, owner, opts \\ []) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {session, owner, opts})
  end

  def send_input(pid, data) when is_pid(pid) and is_binary(data) do
    GenServer.call(pid, {:send_input, data})
  end

  def send_application_request(pid, payload) when is_pid(pid) and is_map(payload) do
    GenServer.call(pid, {:send_application_request, payload})
  end

  def send_file_transfer_data(pid, payload) when is_pid(pid) and is_map(payload) do
    GenServer.call(pid, {:send_file_transfer_data, payload})
  end

  def resize(pid, cols, rows) when is_pid(pid) and is_integer(cols) and is_integer(rows) do
    GenServer.call(pid, {:resize, cols, rows})
  end

  def close(pid, reason) when is_pid(pid) do
    GenServer.cast(pid, {:close, reason})
  end

  @impl true
  def init({session, owner, opts}) do
    Process.monitor(owner)
    :ok = pubsub(opts).subscribe(session_id(session))

    state = %{
      session: session,
      owner: owner,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus),
      required_gateway_node: required_gateway_node(session, opts),
      audit_writer: Keyword.get(opts, :audit_writer, AuditWriter),
      audit_actor: Keyword.get(opts, :audit_actor) || Keyword.get(opts, :actor),
      file_transfers: Keyword.get(opts, :file_transfers, RemoteAccessFileTransfers),
      lifecycle: Keyword.get(opts, :lifecycle, lifecycle_for(session)),
      recordings: Keyword.get(opts, :recordings, RemoteAccessRecordings),
      recording: nil,
      recording_stats: %{input_bytes: 0, output_bytes: 0, event_count: 0},
      pubsub: pubsub(opts),
      closed?: false
    }

    cols = Keyword.get(opts, :cols)
    rows = Keyword.get(opts, :rows)

    case open_frame(session, opts) do
      {:ok, {frame_type, data}} ->
        case send_frame(state, frame_type, data, cols, rows, nil) do
          :ok ->
            lifecycle(state, :mark_opening)

            write_audit(
              state,
              :remote_access_session_opened,
              open_audit_details(data, cols, rows)
            )

            {:ok, start_recording(state)}

          {:error, reason} ->
            lifecycle(state, :fail_session, [reason])
            write_audit(state, :remote_access_session_failed, failure_details(reason))
            {:stop, reason}
        end

      {:error, reason} ->
        lifecycle(state, :fail_session, [reason])
        write_audit(state, :remote_access_session_failed, failure_details(reason))
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_input, data}, _from, state) do
    result = send_frame(state, "data", data, nil, nil, nil)
    write_audit(state, :remote_access_session_input, %{input_bytes: byte_size(data)})
    state = if result == :ok, do: count_recording_input(state, data), else: state
    {:reply, result, state}
  end

  def handle_call({:send_application_request, payload}, _from, state) do
    result = send_frame(state, "app_request", Jason.encode!(payload), nil, nil, nil)

    write_audit(state, :remote_access_application_request, %{
      request_id: string_value(payload, "request_id"),
      method: string_value(payload, "method"),
      path: string_value(payload, "path")
    })

    {:reply, result, state}
  end

  def handle_call({:send_file_transfer_data, payload}, _from, state) do
    result = send_frame(state, "file_transfer_data", Jason.encode!(payload), nil, nil, nil)
    {:reply, result, state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    result = send_frame(state, "resize", "", cols, rows, nil)
    write_audit(state, :remote_access_session_resized, %{cols: uint32(cols), rows: uint32(rows)})
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:close, reason}, state) do
    _ = send_frame(state, "close", "", nil, nil, inspect(reason))
    lifecycle(state, :request_close, [[reason: format_reason(reason)]])

    write_audit(state, :remote_access_session_close_requested, %{
      close_reason: format_reason(reason)
    })

    state = complete_recording(state)

    {:stop, :normal, %{state | closed?: true}}
  end

  @impl true
  def handle_info({:remote_access_frame, frame}, state) when is_map(frame) do
    if owns_remote_access_frame?(state.session, frame) do
      handle_remote_access_frame(frame, state)
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp handle_remote_access_frame(%{frame_type: "ready"}, state) do
    lifecycle(state, :activate_session)
    send(state.owner, {:remote_access_ready, session_id(state.session)})
    state = activate_recording(state)
    {:noreply, state}
  end

  defp handle_remote_access_frame(%{frame_type: "data", data: data}, state)
       when is_binary(data) do
    send(state.owner, {:remote_access_data, data})
    state = count_recording_output(state, data)
    {:noreply, state}
  end

  defp handle_remote_access_frame(%{frame_type: "enhanced_event"} = frame, state) do
    state = count_recording_structured_event(state, frame)
    {:noreply, state}
  end

  defp handle_remote_access_frame(%{frame_type: frame_type} = frame, state)
       when frame_type in @file_transfer_frame_types do
    _ = handle_file_transfer_frame(frame, state)
    send(state.owner, {:remote_access_file_transfer_frame, frame})
    {:noreply, state}
  end

  defp handle_remote_access_frame(%{frame_type: frame_type} = frame, state)
       when frame_type in @application_frame_types do
    send(state.owner, {:remote_access_application_frame, frame})
    state = record_application_or_tcp_frame(:application, frame_type, frame, state)
    maybe_close_application_or_tcp_frame(frame_type, frame, state)
  end

  defp handle_remote_access_frame(%{frame_type: frame_type} = frame, state)
       when frame_type in @tcp_frame_types do
    send(state.owner, {:remote_access_tcp_frame, frame})
    state = record_application_or_tcp_frame(:tcp, frame_type, frame, state)
    maybe_close_application_or_tcp_frame(frame_type, frame, state)
  end

  defp handle_remote_access_frame(%{frame_type: frame_type, reason: reason}, state)
       when frame_type in ["close", "error"] do
    send(state.owner, {:remote_access_closed, reason || frame_type})
    lifecycle_close(state, frame_type, reason || frame_type)
    write_audit(state, close_action(frame_type), %{close_reason: reason || frame_type})
    state = finish_recording_for_close(state, frame_type, reason || frame_type)
    {:stop, :normal, %{state | closed?: true}}
  end

  defp handle_remote_access_frame(frame, state) do
    frame_type = string_value(frame, "frame_type") || "missing"

    Logger.warning("Remote access broker rejected unknown agent frame",
      session_id: session_id(state.session),
      agent_id: agent_id(state.session),
      frame_type: frame_type
    )

    write_audit(state, :remote_access_session_protocol_violation, %{
      frame_type: frame_type,
      rejected_agent_id: string_value(frame, "agent_id"),
      rejected_session_id: string_value(frame, "session_id")
    })

    {:noreply, state}
  end

  defp handle_file_transfer_frame(frame, state) do
    state.file_transfers.handle_agent_frame(frame,
      audit_actor: state.audit_actor,
      audit_writer: state.audit_writer,
      recording: state.recording
    )
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp maybe_close_application_or_tcp_frame(frame_type, frame, state)
       when frame_type in ["app_error", "tcp_error"] do
    reason = agent_frame_reason(frame, frame_type)
    send(state.owner, {:remote_access_closed, reason})
    lifecycle_close(state, "error", reason)
    write_audit(state, :remote_access_session_failed, %{close_reason: reason})
    state = finish_recording_for_close(state, "error", reason)
    {:stop, :normal, %{state | closed?: true}}
  end

  defp maybe_close_application_or_tcp_frame(frame_type, frame, state)
       when frame_type in ["app_close", "tcp_close"] do
    reason = agent_frame_reason(frame, frame_type)
    send(state.owner, {:remote_access_closed, reason})
    lifecycle_close(state, "close", reason)
    write_audit(state, :remote_access_session_closed, %{close_reason: reason})
    state = finish_recording_for_close(state, "close", reason)
    {:stop, :normal, %{state | closed?: true}}
  end

  defp maybe_close_application_or_tcp_frame(_frame_type, _frame, state), do: {:noreply, state}

  defp agent_frame_reason(frame, fallback_reason) do
    string_value(frame, "reason") ||
      frame
      |> value("data")
      |> decode_frame_data()
      |> frame_payload_reason() ||
      fallback_reason
  end

  defp frame_payload_reason(payload) do
    string_value(payload, "message") || string_value(payload, "reason")
  end

  defp decode_frame_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp decode_frame_data(_data), do: %{}

  defp owns_remote_access_frame?(session, frame) do
    string_value(frame, "session_id") == session_id(session) and
      string_value(frame, "agent_id") == agent_id(session)
  end

  @impl true
  def terminate(reason, %{closed?: false} = state) do
    _ = send_frame(state, "close", "", nil, nil, inspect(reason))

    if reason in [:normal, :shutdown] do
      _ = complete_recording(state)
    else
      lifecycle(state, :fail_session, [reason])
      write_audit(state, :remote_access_session_failed, failure_details(reason))
      _ = fail_recording(state, reason)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_recording(state) do
    case state.recordings.ensure_for_session(state.session, recording_opts(state)) do
      {:ok, recording} -> %{state | recording: recording}
      {:error, _reason} -> state
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp activate_recording(%{recording: nil} = state), do: state

  defp activate_recording(state) do
    case state.recordings.activate(state.recording, recording_opts(state)) do
      {:ok, recording} -> %{state | recording: recording}
      {:error, _reason} -> state
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp count_recording_input(%{recording: nil} = state, _data), do: state

  defp count_recording_input(state, data) do
    record_replay_event(state, %{
      stream: :input,
      event_type: "terminal_input",
      data: data,
      sequence: state.recording_stats.event_count + 1
    })

    update_in(state.recording_stats, fn stats ->
      %{
        stats
        | input_bytes: stats.input_bytes + byte_size(data),
          event_count: stats.event_count + 1
      }
    end)
  end

  defp count_recording_output(%{recording: nil} = state, _data), do: state

  defp count_recording_output(state, data) do
    record_replay_event(state, %{
      stream: :output,
      event_type: "terminal_output",
      data: data,
      sequence: state.recording_stats.event_count + 1
    })

    update_in(state.recording_stats, fn stats ->
      %{
        stats
        | output_bytes: stats.output_bytes + byte_size(data),
          event_count: stats.event_count + 1
      }
    end)
  end

  defp count_recording_structured_event(%{recording: nil} = state, _frame), do: state

  defp count_recording_structured_event(state, frame) do
    record_replay_event(state, %{
      stream: :enhanced_event,
      event_type: string_value(frame, "event_type") || "enhanced_event",
      data: value(frame, "data"),
      metadata:
        %{
          agent_id: string_value(frame, "agent_id"),
          gateway_id: string_value(frame, "gateway_id"),
          protocol: string_value(frame, "protocol"),
          timestamp: value(frame, "timestamp")
        }
        |> Enum.reject(fn {_key, value} -> blank?(value) end)
        |> Map.new(),
      sequence: state.recording_stats.event_count + 1
    })

    update_in(state.recording_stats.event_count, &(&1 + 1))
  end

  defp record_application_or_tcp_frame(kind, frame_type, frame, state) do
    payload = frame |> value("data") |> decode_frame_data()
    metadata = application_tcp_metadata(kind, frame_type, frame, payload)
    write_audit(state, application_tcp_audit_action(kind, frame_type, payload), metadata)

    count_recording_application_tcp_event(state, kind, frame_type, metadata)
  end

  defp count_recording_application_tcp_event(
         %{recording: nil} = state,
         _kind,
         _frame_type,
         _metadata
       ), do: state

  defp count_recording_application_tcp_event(state, kind, frame_type, metadata) do
    record_replay_event(state, %{
      stream: kind,
      event_type: frame_type,
      metadata: metadata,
      sequence: state.recording_stats.event_count + 1
    })

    update_in(state.recording_stats, fn stats ->
      %{
        stats
        | input_bytes: stats.input_bytes + input_byte_count(metadata),
          output_bytes: stats.output_bytes + output_byte_count(metadata),
          event_count: stats.event_count + 1
      }
    end)
  end

  defp application_tcp_metadata(kind, frame_type, frame, payload) do
    %{
      kind: Atom.to_string(kind),
      frame_type: frame_type,
      agent_id: string_value(frame, "agent_id"),
      gateway_node: string_value(frame, "gateway_node"),
      timestamp: value(frame, "timestamp"),
      request_id: string_value(payload, "request_id"),
      connection_id: string_value(payload, "connection_id"),
      target_id: string_value(payload, "target_id"),
      status: string_value(payload, "status"),
      code: string_value(payload, "code"),
      status_code: positive_int(value(payload, "status_code")),
      direction: string_value(payload, "direction"),
      sequence: positive_int(value(payload, "sequence")),
      eof: truthy?(value(payload, "eof")),
      request_bytes: positive_int(value(payload, "request_bytes")),
      response_bytes: positive_int(value(payload, "response_bytes")),
      bytes_in: positive_int(value(payload, "bytes_in")),
      bytes_out: positive_int(value(payload, "bytes_out")),
      body_bytes: body_byte_count(payload)
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp application_tcp_audit_action(:application, "app_response_metadata", _payload),
    do: :remote_access_application_response

  defp application_tcp_audit_action(:application, "app_data", _payload),
    do: :remote_access_application_data

  defp application_tcp_audit_action(:application, "app_progress", %{"status" => "started"}),
    do: :remote_access_application_started

  defp application_tcp_audit_action(:application, "app_progress", _payload),
    do: :remote_access_application_progress

  defp application_tcp_audit_action(:application, "app_error", %{"status" => "quota_exhausted"}),
    do: :remote_access_application_quota_exhausted

  defp application_tcp_audit_action(:application, "app_error", _payload),
    do: :remote_access_application_failed

  defp application_tcp_audit_action(:application, "app_close", _payload),
    do: :remote_access_application_closed

  defp application_tcp_audit_action(:application, _frame_type, _payload),
    do: :remote_access_application_event

  defp application_tcp_audit_action(:tcp, "tcp_data", _payload), do: :remote_access_tcp_data

  defp application_tcp_audit_action(:tcp, "tcp_progress", %{"status" => "started"}),
    do: :remote_access_tcp_started

  defp application_tcp_audit_action(:tcp, "tcp_progress", _payload),
    do: :remote_access_tcp_progress

  defp application_tcp_audit_action(:tcp, "tcp_error", %{"status" => "quota_exhausted"}),
    do: :remote_access_tcp_quota_exhausted

  defp application_tcp_audit_action(:tcp, "tcp_error", _payload), do: :remote_access_tcp_failed
  defp application_tcp_audit_action(:tcp, "tcp_close", _payload), do: :remote_access_tcp_closed
  defp application_tcp_audit_action(:tcp, _frame_type, _payload), do: :remote_access_tcp_event

  defp input_byte_count(%{direction: "request", body_bytes: bytes}) when is_integer(bytes),
    do: bytes

  defp input_byte_count(%{direction: "client", body_bytes: bytes}) when is_integer(bytes),
    do: bytes

  defp input_byte_count(%{request_bytes: bytes}) when is_integer(bytes), do: bytes
  defp input_byte_count(%{bytes_in: bytes}) when is_integer(bytes), do: bytes
  defp input_byte_count(_metadata), do: 0

  defp output_byte_count(%{direction: "response", body_bytes: bytes}) when is_integer(bytes),
    do: bytes

  defp output_byte_count(%{direction: "upstream", body_bytes: bytes}) when is_integer(bytes),
    do: bytes

  defp output_byte_count(%{response_bytes: bytes}) when is_integer(bytes), do: bytes
  defp output_byte_count(%{bytes_out: bytes}) when is_integer(bytes), do: bytes
  defp output_byte_count(_metadata), do: 0

  defp body_byte_count(%{"data" => data}) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> byte_size(decoded)
      :error -> byte_size(data)
    end
  end

  defp body_byte_count(_payload), do: nil

  defp record_replay_event(%{recording: nil}, _attrs), do: :ok

  defp record_replay_event(state, attrs) do
    _ = state.recordings.record_event(state.recording, attrs, recording_opts(state))
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp finish_recording_for_close(state, "error", reason), do: fail_recording(state, reason)
  defp finish_recording_for_close(state, _frame_type, _reason), do: complete_recording(state)

  defp complete_recording(%{recording: nil} = state), do: state

  defp complete_recording(state) do
    _ = state.recordings.complete(state.recording, state.recording_stats, recording_opts(state))
    %{state | recording: nil}
  rescue
    _error -> %{state | recording: nil}
  catch
    _kind, _reason -> %{state | recording: nil}
  end

  defp fail_recording(%{recording: nil} = state, _reason), do: state

  defp fail_recording(state, reason) do
    _ =
      state.recordings.fail(state.recording, reason, state.recording_stats, recording_opts(state))

    %{state | recording: nil}
  rescue
    _error -> %{state | recording: nil}
  catch
    _kind, _reason -> %{state | recording: nil}
  end

  defp recording_opts(state) do
    [
      audit_writer: state.audit_writer,
      audit_actor: state.audit_actor
    ]
  end

  defp send_frame(state, frame_type, data, cols, rows, reason) do
    frame = %{
      session_id: session_id(state.session),
      frame_type: frame_type,
      data: data || "",
      cols: uint32(cols),
      rows: uint32(rows),
      reason: reason || "",
      timestamp: System.system_time(:second)
    }

    state.command_bus.send_console_frame(agent_id(state.session), frame,
      required_gateway_node: state.required_gateway_node
    )
  end

  defp write_audit(state, action, extra_details) do
    details =
      state.session
      |> base_audit_details()
      |> Map.merge(extra_details)
      |> sanitize_audit_details()

    state.audit_writer.write_async(
      action: action,
      resource_type: "remote_access_session",
      resource_id: session_id(state.session),
      resource_name: target_ref(Map.get(details, :target)),
      actor: state.audit_actor,
      details: details,
      severity: audit_severity(action),
      message: "Remote access session #{audit_suffix(action)}"
    )
  end

  defp base_audit_details(session) do
    %{
      session_id: session_id(session),
      agent_id: agent_id(session),
      gateway_id: value(session, "gateway_id"),
      protocol:
        string_value(metadata(session), "protocol") || string_value(session, "protocol") ||
          @default_protocol,
      credential_mode:
        string_value(metadata(session), "credential_mode") ||
          string_value(metadata(session), "credential_custody_mode") ||
          string_value(session, "credential_mode") ||
          string_value(session, "credential_custody_mode") ||
          @default_credential_mode,
      target: target(session, %{}, metadata(session))
    }
  end

  defp open_audit_details(data, cols, rows) do
    data
    |> Jason.decode()
    |> case do
      {:ok, decoded} when is_map(decoded) ->
        %{
          protocol: Map.get(decoded, "protocol"),
          credential_mode: Map.get(decoded, "credential_mode"),
          agent_id: Map.get(decoded, "agent_id"),
          gateway_id: Map.get(decoded, "gateway_id"),
          target: Map.get(decoded, "target"),
          terminal_type: Map.get(decoded, "terminal_type"),
          ssh_host_key_policy: Map.get(decoded, "ssh_host_key_policy"),
          cols: uint32(cols),
          rows: uint32(rows)
        }

      _error ->
        %{cols: uint32(cols), rows: uint32(rows)}
    end
  end

  defp failure_details(reason), do: %{failure_reason: format_reason(reason)}

  defp sanitize_audit_details(details) do
    details
    |> stringify_nested()
    |> Map.delete("ssh")
    |> Map.delete(:ssh)
    |> CredentialRedactor.redact()
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new(fn {key, value} -> {normalize_audit_key(key), value} end)
  end

  defp normalize_audit_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_audit_key(key), do: key

  defp target_ref(target) when is_map(target) do
    string_value(target, "id") ||
      string_value(target, "device_uid") ||
      string_value(target, "uid") ||
      string_value(target, "host")
  end

  defp target_ref(_target), do: nil

  defp close_action("error"), do: :remote_access_session_failed
  defp close_action(_frame_type), do: :remote_access_session_closed

  defp audit_severity(:remote_access_session_failed), do: :high
  defp audit_severity(:remote_access_session_protocol_violation), do: :high
  defp audit_severity(_action), do: :medium

  defp audit_suffix(:remote_access_session_opened), do: "opened"
  defp audit_suffix(:remote_access_session_input), do: "input"
  defp audit_suffix(:remote_access_session_resized), do: "resized"
  defp audit_suffix(:remote_access_session_close_requested), do: "close requested"
  defp audit_suffix(:remote_access_session_closed), do: "closed"
  defp audit_suffix(:remote_access_session_failed), do: "failed"
  defp audit_suffix(:remote_access_session_protocol_violation), do: "protocol violation"
  defp audit_suffix(action), do: Atom.to_string(action)

  defp lifecycle_for(%RemoteAccessSession{}), do: RemoteAccessSessions
  defp lifecycle_for(_session), do: nil

  defp lifecycle(%{lifecycle: nil}, _function), do: :ok
  defp lifecycle(state, function), do: lifecycle(state, function, [[]])

  defp lifecycle(%{lifecycle: nil}, _function, _args), do: :ok

  defp lifecycle(state, function, args) do
    _ = apply(state.lifecycle, function, [session_id(state.session) | args])
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp lifecycle_close(state, "error", reason),
    do: lifecycle(state, :fail_session, [reason, [outcome: :protocol_error]])

  defp lifecycle_close(state, _frame_type, reason),
    do: lifecycle(state, :close_session, [[reason: reason, outcome: :completed]])

  defp format_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_reason(reason) do
    reason
    |> inspect()
    |> String.slice(0, 500)
  end

  defp open_frame(session, opts) do
    case session_protocol(session, opts) do
      "app" -> application_open_frame_data(session)
      "application" -> application_open_frame_data(session)
      "tcp" -> tcp_open_frame_data(session)
      _protocol -> terminal_open_frame_data(session, opts)
    end
  end

  defp terminal_open_frame_data(session, opts) do
    session_metadata = metadata(session)
    opts_metadata = opts |> Keyword.get(:metadata, %{}) |> normalize_metadata()
    ssh_certificate = ssh_certificate_envelope(session, opts, opts_metadata, session_metadata)
    session_target = target(session, opts_metadata, session_metadata)
    credential_broker = credential_broker_grant(opts_metadata)

    with :ok <- validate_ssh_certificate_envelope(session, ssh_certificate, session_target),
         {:ok, ssh_host_key_policy} <- ssh_host_key_policy_option(session, opts) do
      target =
        ssh_certificate
        |> certificate_target()
        |> merge_certificate_target(session_target)

      ssh = ssh_auth(session, opts_metadata, session_metadata, ssh_certificate, credential_broker)

      data =
        %{
          protocol: string_option(session, opts, "protocol", @default_protocol),
          session_id: session_id(session),
          agent_id: agent_id(session),
          gateway_id: value(session, "gateway_id"),
          target: target,
          ssh: ssh,
          credential_broker: credential_broker,
          credential_mode:
            credential_mode(session, opts, opts_metadata, session_metadata, ssh_certificate),
          terminal_type: string_option(session, opts, "terminal_type", @default_terminal_type),
          timeout_ms: int_option(session, opts, "timeout_ms"),
          ssh_host_key_policy: ssh_host_key_policy,
          recording_policy: policy_option(session, opts, "recording_policy"),
          enhanced_recording_policy: policy_option(session, opts, "enhanced_recording_policy")
        }
        |> Enum.reject(fn {_key, value} -> blank?(value) end)
        |> Map.new()
        |> Jason.encode!()

      {:ok, {"open", data}}
    end
  end

  defp application_open_frame_data(session) do
    session_metadata = metadata(session)

    data =
      encode_typed_open_payload(%{
        target_id: string_value(session_metadata, "target_id"),
        session_id: session_id(session),
        scheme: string_value(session_metadata, "upstream_scheme"),
        upstream_host: string_value(session, "target_host"),
        upstream_port: positive_int(value(session, "target_port")),
        host_header: string_value(session_metadata, "upstream_host_header"),
        sni: string_value(session_metadata, "upstream_sni"),
        tls_policy: policy_metadata(session_metadata, "tls_policy"),
        ca_bundle_ref: string_value(session_metadata, "ca_bundle_ref"),
        allowed_methods: list_metadata(session_metadata, "allowed_methods"),
        allowed_path_prefixes: list_metadata(session_metadata, "allowed_path_prefixes"),
        header_policy: policy_metadata(session_metadata, "header_policy"),
        cookie_policy: policy_metadata(session_metadata, "cookie_policy"),
        quota_policy: policy_metadata(session_metadata, "quota_policy"),
        approval_id: string_value(session, "approval_id"),
        recording_policy: policy_option(session, [], "recording_policy"),
        enhanced_recording_policy: policy_option(session, [], "enhanced_recording_policy"),
        metadata: policy_metadata(session_metadata, "target_metadata")
      })

    {:ok, {"app_open", data}}
  end

  defp tcp_open_frame_data(session) do
    session_metadata = metadata(session)
    session_id = session_id(session)

    data =
      encode_typed_open_payload(%{
        target_id: string_value(session_metadata, "target_id"),
        session_id: session_id,
        connection_id: string_value(session_metadata, "connection_id") || "#{session_id}:tcp",
        upstream_host: string_value(session, "target_host"),
        upstream_port: positive_int(value(session, "target_port")),
        protocol_name: string_value(session_metadata, "protocol_name"),
        idle_timeout_seconds: positive_int(value(session, "idle_timeout_seconds")),
        absolute_timeout_seconds: positive_int(value(session, "absolute_timeout_seconds")),
        quota_policy: policy_metadata(session_metadata, "quota_policy"),
        approval_id: string_value(session, "approval_id"),
        recording_policy: policy_option(session, [], "recording_policy"),
        enhanced_recording_policy: policy_option(session, [], "enhanced_recording_policy"),
        metadata: policy_metadata(session_metadata, "target_metadata")
      })

    {:ok, {"tcp_open", data}}
  end

  defp session_protocol(session, opts),
    do: string_option(session, opts, "protocol", @default_protocol)

  defp required_gateway_node(session, opts) do
    case Keyword.get(opts, :required_gateway_node) do
      nil ->
        string_value(session, "gateway_node") || string_value(metadata(session), "gateway_node")

      value ->
        value
    end
  end

  defp encode_typed_open_payload(payload) do
    payload
    |> Enum.reject(fn {_key, value} -> empty_payload_value?(value) end)
    |> Map.new()
    |> CredentialRedactor.redact()
    |> Jason.encode!()
  end

  defp empty_payload_value?(value) when value in [nil, "", 0], do: true
  defp empty_payload_value?(value) when is_map(value), do: map_size(value) == 0
  defp empty_payload_value?(value) when is_list(value), do: value == []
  defp empty_payload_value?(_value), do: false

  defp policy_metadata(session_metadata, key) do
    session_metadata
    |> map_value(key)
    |> normalize_metadata()
    |> non_empty_map()
    |> sanitize_policy()
  end

  defp list_metadata(session_metadata, key) do
    case map_value(session_metadata, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&string_or_nil/1)
        |> Enum.reject(&is_nil/1)

      _value ->
        nil
    end
  end

  defp ssh_certificate_envelope(_session, opts, opts_metadata, _session_metadata) do
    opts
    |> Keyword.get(:ssh_certificate)
    |> fallback(map_value(opts_metadata, "ssh_certificate"))
    |> fallback(map_value(opts_metadata, "certificate_envelope"))
    |> normalize_metadata()
  end

  defp credential_broker_grant(opts_metadata) do
    opts_metadata
    |> map_value("credential_broker")
    |> normalize_metadata()
    |> non_empty_map()
  end

  defp certificate_target(certificate) do
    certificate
    |> map_value("target")
    |> normalize_target()
    |> non_empty_map()
  end

  defp validate_ssh_certificate_envelope(_session, certificate, _session_target)
       when certificate == %{}, do: :ok

  defp validate_ssh_certificate_envelope(session, certificate, session_target) do
    with :ok <-
           optional_match(
             certificate,
             "session_id",
             session_id(session),
             :ssh_certificate_session_mismatch
           ),
         :ok <-
           optional_match(
             certificate,
             "agent_id",
             agent_id(session),
             :ssh_certificate_agent_mismatch
           ),
         :ok <- optional_match(certificate, "protocol", "ssh", :ssh_certificate_protocol_mismatch),
         :ok <-
           optional_match(
             certificate,
             "credential_mode",
             "ssh_certificate",
             :ssh_certificate_mode_invalid
           ),
         :ok <- validate_ssh_certificate_target(certificate_target(certificate), session_target) do
      validate_ssh_certificate_auth(certificate)
    end
  end

  defp validate_ssh_certificate_target(certificate_target, _session_target)
       when certificate_target == %{}, do: :ok

  defp validate_ssh_certificate_target(certificate_target, session_target) do
    conflict? =
      Enum.any?(["id", "device_uid", "uid", "host", "port"], fn key ->
        certificate_value = comparable_target_value(certificate_target, key)
        session_value = comparable_target_value(session_target, key)

        not blank?(certificate_value) and not blank?(session_value) and
          certificate_value != session_value
      end)

    if conflict?, do: {:error, :ssh_certificate_target_mismatch}, else: :ok
  end

  defp validate_ssh_certificate_auth(certificate) do
    auth =
      certificate
      |> map_value("ssh")
      |> normalize_ssh_auth()

    cond do
      blank?(Map.get(auth, "username")) -> {:error, :ssh_certificate_username_required}
      blank?(Map.get(auth, "certificate")) -> {:error, :ssh_certificate_required}
      true -> :ok
    end
  end

  defp optional_match(container, key, expected, error) do
    case string_value(container, key) do
      nil -> :ok
      ^expected -> :ok
      _other -> {:error, error}
    end
  end

  defp target(session, opts_metadata, session_metadata) do
    session
    |> target_from_session()
    |> non_empty_map()
    |> fallback(map_value(session_metadata, "target"))
    |> fallback(map_value(opts_metadata, "target"))
    |> fallback(value(session, "target"))
    |> normalize_target()
  end

  defp merge_certificate_target(certificate_target, session_target) do
    certificate_target
    |> fallback(%{})
    |> Map.merge(session_target)
    |> non_empty_map()
  end

  defp comparable_target_value(target, key),
    do: target |> map_value(key) |> target_compare_string()

  defp target_compare_string(value) when is_integer(value), do: Integer.to_string(value)
  defp target_compare_string(value), do: string_or_nil(value)

  defp target_from_session(session) do
    %{
      "device_uid" => string_value(session, "device_uid"),
      "host" => string_value(session, "target_host"),
      "port" => positive_int(value(session, "target_port"))
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp normalize_target(target) when is_map(target) do
    target
    |> stringify_map()
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp normalize_target(_target), do: %{}

  defp ssh_auth(_session, _opts_metadata, _session_metadata, _ssh_certificate, credential_broker)
       when is_map(credential_broker), do: %{}

  defp ssh_auth(_session, opts_metadata, _session_metadata, ssh_certificate, _credential_broker) do
    session_auth =
      opts_metadata
      |> map_value("ssh")
      |> normalize_ssh_auth()

    certificate_auth =
      ssh_certificate
      |> map_value("ssh")
      |> normalize_ssh_auth()

    Map.merge(session_auth, certificate_auth)
  end

  defp normalize_ssh_auth(auth) when is_map(auth) do
    auth
    |> stringify_map()
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp normalize_ssh_auth(_auth), do: %{}

  defp credential_mode(session, opts, opts_metadata, session_metadata, ssh_certificate) do
    opts
    |> Keyword.get(:credential_mode, nil)
    |> string_or_nil()
    |> fallback(string_value(ssh_certificate, "credential_mode"))
    |> fallback(string_value(opts_metadata, "credential_mode"))
    |> fallback(string_value(session_metadata, "credential_mode"))
    |> fallback(string_value(session_metadata, "credential_custody_mode"))
    |> fallback(string_value(session, "credential_mode"))
    |> fallback(string_value(session, "credential_custody_mode"))
    |> fallback(@default_credential_mode)
  end

  defp ssh_host_key_policy_option(session, opts) do
    policy = string_option(session, opts, "ssh_host_key_policy", @default_ssh_host_key_policy)

    if policy in @ssh_host_key_policies do
      {:ok, policy}
    else
      {:error, :unsupported_ssh_host_key_policy}
    end
  end

  defp string_option(session, opts, key, default) do
    opts
    |> Keyword.get(String.to_existing_atom(key), nil)
    |> string_or_nil()
    |> fallback(string_value(metadata(session), key))
    |> fallback(string_value(session, key))
    |> fallback(default)
  rescue
    ArgumentError ->
      string_value(metadata(session), key) || string_value(session, key) || default
  end

  defp int_option(session, opts, key) do
    opts
    |> Keyword.get(String.to_existing_atom(key), nil)
    |> positive_int()
    |> fallback(positive_int(map_value(metadata(session), key)))
    |> fallback(positive_int(value(session, key)))
  rescue
    ArgumentError ->
      positive_int(map_value(metadata(session), key)) || positive_int(value(session, key))
  end

  defp policy_option(session, opts, key) do
    opts
    |> Keyword.get(safe_existing_atom(key), nil)
    |> normalize_metadata()
    |> non_empty_map()
    |> fallback(
      session
      |> metadata()
      |> map_value(key)
      |> normalize_metadata()
      |> non_empty_map()
    )
    |> fallback(session |> value(key) |> normalize_metadata() |> non_empty_map())
    |> sanitize_policy()
  end

  defp sanitize_policy(nil), do: nil
  defp sanitize_policy(policy) when is_map(policy), do: CredentialRedactor.redact(policy)
  defp sanitize_policy(_policy), do: nil

  defp metadata(session), do: session |> value("metadata") |> normalize_metadata()

  defp normalize_metadata(metadata) when is_map(metadata), do: stringify_map(metadata)
  defp normalize_metadata(_metadata), do: %{}

  defp session_id(session),
    do: string_value(session, "id") || string_value(session, "session_id") || ""

  defp agent_id(session), do: string_value(session, "agent_id") || ""

  defp string_value(container, key), do: container |> value(key) |> string_or_nil()

  defp value(container, key) when is_map(container) do
    atom_key = safe_existing_atom(key)
    Map.get(container, key) || (atom_key && Map.get(container, atom_key))
  end

  defp value(_container, _key), do: nil

  defp map_value(container, key), do: value(container, key)

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp string_or_nil(nil), do: nil

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp string_or_nil(_value), do: nil

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp positive_int(_value), do: nil

  defp fallback(nil, fallback), do: fallback
  defp fallback(value, _fallback), do: value

  defp non_empty_map(%{} = map) when map_size(map) == 0, do: nil
  defp non_empty_map(%{} = map), do: map

  defp blank?(value) when value in [nil, "", 0], do: true
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(_value), do: false

  defp truthy?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp stringify_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} -> {to_string(key), stringify_nested(value)}
    end)
  end

  defp stringify_nested(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_nested(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_nested(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_nested(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify_nested(%_{} = value), do: value
  defp stringify_nested(value) when is_map(value), do: stringify_map(value)
  defp stringify_nested(value), do: value

  defp uint32(value) when is_integer(value) and value > 0, do: min(value, 65_535)
  defp uint32(_value), do: 0

  defp pubsub(opts), do: Keyword.get(opts, :pubsub, RemoteAccessPubSub)
end
