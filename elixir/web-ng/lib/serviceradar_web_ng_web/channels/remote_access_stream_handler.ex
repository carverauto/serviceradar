defmodule ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandler do
  @moduledoc """
  Browser-facing WebSock handler for generic remote-access streams.

  The browser first sends an attach frame containing the short-lived ticket.
  After attach, only terminal/protocol bytes, resize requests, ready, close, and
  sanitized error messages cross the browser boundary. A close caused by SSH
  host-key verification additionally carries the target address and the offered
  public key's algorithm and fingerprint, so the console can present the trust
  decision instead of a dead end. See `ServiceRadarWebNGWeb.Channels.RemoteAccessHostKeyFailure`.
  """

  @behaviour WebSock

  alias ServiceRadar.Edge.RemoteAccessBroker
  alias ServiceRadar.Edge.RemoteAccessCentralCredentialGrants
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSessions
  alias ServiceRadar.Edge.RemoteAccessSSHSessionCredentials
  alias ServiceRadarWebNG.RemoteDesktopWebRTC
  alias ServiceRadarWebNGWeb.Channels.RemoteAccessHostKeyFailure

  require Logger

  @min_terminal_cols 1
  @max_terminal_cols 500
  @min_terminal_rows 1
  @max_terminal_rows 200
  @max_browser_data_frame_bytes 65_536
  @max_browser_data_frame_encoded_bytes div(@max_browser_data_frame_bytes + 2, 3) * 4
  @max_application_header_count 32
  @max_application_header_name_bytes 128
  @max_application_header_value_bytes 4_096
  @max_application_data_frame_bytes 65_536
  @max_application_data_frame_encoded_bytes div(@max_application_data_frame_bytes + 2, 3) * 4
  @max_application_path_bytes 2_048
  @max_application_query_bytes 4_096
  @max_application_request_id_bytes 128
  @max_application_sequence 9_223_372_036_854_775_807
  @application_methods ~w(GET HEAD OPTIONS POST PUT PATCH DELETE)
  @max_tcp_connection_id_bytes 128
  @max_tcp_data_frame_bytes 65_536
  @max_tcp_data_frame_encoded_bytes div(@max_tcp_data_frame_bytes + 2, 3) * 4
  @max_tcp_sequence 9_223_372_036_854_775_807
  @max_file_transfer_chunk_bytes 65_536
  @max_file_transfer_chunk_encoded_bytes div(@max_file_transfer_chunk_bytes + 2, 3) * 4
  @max_username_bytes 128
  @max_private_key_bytes 65_536
  @max_public_key_bytes 16_384
  @max_password_bytes 4_096
  @max_passphrase_bytes 4_096
  @default_reauth_interval_ms 30_000
  @desktop_activity_persist_interval_ms 30_000
  @credential_controlled_keys ~w(
    accounts
    agent_id
    allowed_principals
    claims
    credential_mode
    gateway_id
    idp_claims
    principal_mappings
    principals
    requested_principals
    session_id
    ssh_accounts
    ssh_allowed_principals
    ssh_principal_mappings
    target
    ttl_seconds
  )

  @impl true
  def init(options) do
    {:ok,
     %{
       session_id: Keyword.fetch!(options, :session_id),
       scope: Keyword.fetch!(options, :scope),
       broker_module: Keyword.get(options, :broker_module, RemoteAccessBroker),
       sessions_module: Keyword.get(options, :sessions_module, RemoteAccessSessions),
       credential_grant_resolver: Keyword.get(options, :credential_grant_resolver, RemoteAccessCentralCredentialGrants),
       desktop_webrtc_module: Keyword.get(options, :desktop_webrtc_module, RemoteDesktopWebRTC),
       authorization_module: Keyword.get(options, :authorization_module, ServiceRadarWebNG.RBAC),
       reauth_interval_ms: Keyword.get(options, :reauth_interval_ms, @default_reauth_interval_ms),
       broker: nil,
       session: nil,
       attached?: false,
       idle_timer: nil,
       absolute_timer: nil,
       reauth_timer: nil,
       last_activity_persisted_at_ms: nil,
       closing_action: nil
     }}
  end

  @impl true
  def handle_in({data, [opcode: :text]}, %{attached?: false} = state) do
    with {:ok, %{"type" => "attach"} = message} <- decode_json(data),
         {:ok, ticket} <- required_string(message, "ticket"),
         :ok <- ensure_session_id(message, state.session_id),
         {:ok, %RemoteAccessSession{} = session, state} <- attach_with_current_authority(ticket, state),
         {:ok, broker} <- start_broker(session, message, state) do
      state =
        state
        |> cancel_timeout_timers()
        |> Map.merge(%{attached?: true, session: session, broker: broker})
        |> schedule_timeout_timers(session)
        |> schedule_reauth_timer()

      {:push, {:text, encode(%{type: "ready", session_id: session.id})}, state}
    else
      {:error, :remote_access_broker_unavailable} ->
        _ = state.sessions_module.fail_session(state.session_id, :remote_access_broker_unavailable, scope: state.scope)

        {:stop, :normal, 1011,
         [{:text, encode(%{type: "error", message: "Remote access broker is not available on the edge agent yet."})}],
         state}

      {:error, reason} when reason in [:session_credential_required, :ssh_username_required] ->
        _ = state.sessions_module.fail_session(state.session_id, reason, scope: state.scope)

        {:stop, :normal, 1008, [{:text, encode(%{type: "error", message: "A per-session SSH credential is required."})}],
         state}

      {:error, reason} when reason in [:credential_policy_denied, :invalid_request, :invalid_size] ->
        _ = state.sessions_module.fail_session(state.session_id, reason, scope: state.scope)

        {:stop, :normal, 1008,
         [{:text, encode(%{type: "error", message: "The supplied SSH credential was rejected by policy."})}], state}

      {:error, :permission_revoked, denied_state} ->
        stop_for_permission_revoked(denied_state)

      {:error, reason} ->
        Logger.warning("Remote access websocket attach rejected",
          session_id: state.session_id,
          reason: inspect(reason)
        )

        {:stop, :normal, 1008, [{:text, encode(%{type: "error", message: "Invalid or expired remote access ticket."})}],
         state}
    end
  end

  def handle_in({data, [opcode: :text]}, state) do
    case ensure_current_authority(state) do
      {:ok, state} ->
        case decode_json(data) do
          {:ok, %{"type" => "data", "data" => encoded}} when is_binary(encoded) ->
            with {:ok, payload} <- decode_base64(encoded),
                 :ok <- state.broker_module.send_input(state.broker, payload) do
              {:ok, reset_idle_timer(state)}
            else
              {:error, reason} -> handle_broker_error(reason, state)
            end

          {:ok, %{"type" => "resize", "cols" => cols, "rows" => rows}} ->
            with {:ok, cols} <- terminal_int(cols, @min_terminal_cols, @max_terminal_cols),
                 {:ok, rows} <- terminal_int(rows, @min_terminal_rows, @max_terminal_rows),
                 :ok <- state.broker_module.resize(state.broker, cols, rows) do
              {:ok, reset_idle_timer(state)}
            else
              {:error, reason} -> handle_broker_error(reason, state)
            end

          {:ok, %{"type" => "app_request"} = message} ->
            with {:ok, payload} <- application_request_payload(message),
                 :ok <- state.broker_module.send_application_request(state.broker, payload) do
              {:ok, reset_idle_timer(state)}
            else
              {:error, reason} -> handle_broker_error(reason, state)
            end

          {:ok, %{"type" => "app_data"} = message} ->
            with {:ok, payload} <- application_data_payload(message),
                 :ok <- state.broker_module.send_application_data(state.broker, payload) do
              {:ok, reset_idle_timer(state)}
            else
              {:error, reason} -> handle_broker_error(reason, state)
            end

          {:ok, %{"type" => "tcp_data"} = message} ->
            with {:ok, payload} <- tcp_data_payload(message),
                 :ok <- state.broker_module.send_tcp_data(state.broker, payload) do
              {:ok, reset_idle_timer(state)}
            else
              {:error, reason} -> handle_broker_error(reason, state)
            end

          {:ok, %{"type" => "file_transfer_data"} = message} ->
            with {:ok, payload} <- file_transfer_data_payload(message),
                 :ok <- state.broker_module.send_file_transfer_data(state.broker, payload) do
              {:ok, reset_idle_timer(state)}
            else
              {:error, reason} -> handle_broker_error(reason, state)
            end

          {:ok, %{"type" => "activity"} = message} ->
            case record_desktop_activity(message, state) do
              {:ok, next_state} -> {:ok, next_state}
              {:error, reason} -> stop_for_broker_error(reason, state)
            end

          {:ok, %{"type" => "attach"}} ->
            {:ok, state}

          other ->
            log_unknown_stream_message(unknown_browser_message_type(other), state, :browser_text)
            {:ok, state}
        end

      {:error, :permission_revoked} ->
        stop_for_permission_revoked(state)
    end
  end

  def handle_in({_data, [opcode: :binary]}, state) do
    case ensure_current_authority(state) do
      {:ok, state} ->
        log_unknown_stream_message("binary", state, :browser_binary)
        {:ok, state}

      {:error, :permission_revoked} ->
        stop_for_permission_revoked(state)
    end
  end

  @impl true
  def handle_info({:remote_access_ready, session_id}, state) do
    with_current_authority(state, fn state ->
      {:push, {:text, encode(%{type: "adapter_ready", session_id: session_id})}, state}
    end)
  end

  def handle_info({:remote_access_data, payload}, state) when is_binary(payload) do
    with_current_authority(state, fn state ->
      {:push, {:text, encode(%{type: "data", data: Base.encode64(payload)})}, reset_idle_timer(state)}
    end)
  end

  def handle_info({:remote_access_file_transfer_frame, frame}, state) when is_map(frame) do
    with_current_authority(state, fn state ->
      {:push, {:text, encode(file_transfer_message(frame, state))}, reset_idle_timer(state)}
    end)
  end

  def handle_info({:remote_access_application_frame, frame}, state) when is_map(frame) do
    with_current_authority(state, fn state ->
      {:push, {:text, encode(application_message(frame, state))}, reset_idle_timer(state)}
    end)
  end

  def handle_info({:remote_access_tcp_frame, frame}, state) when is_map(frame) do
    with_current_authority(state, fn state ->
      {:push, {:text, encode(tcp_message(frame, state))}, reset_idle_timer(state)}
    end)
  end

  def handle_info({:remote_access_closed, reason}, state) do
    with_current_authority(state, fn state ->
      close_reason = format_close_reason(reason)

      _ =
        state.sessions_module.close_session(state.session.id,
          reason: close_reason,
          scope: state.scope
        )

      {:stop, :normal, 1000, [{:text, encode(close_message(close_reason))}], %{state | closing_action: :closed}}
    end)
  end

  def handle_info(:idle_timeout, state) do
    _ = state.sessions_module.expire_session(state.session.id, reason: "idle_timeout", scope: state.scope)

    {:stop, :normal, 1000,
     [{:text, encode(%{type: "error", message: "Remote access session closed after idle timeout."})}],
     %{state | closing_action: :expired}}
  end

  def handle_info(:absolute_timeout, state) do
    _ = state.sessions_module.expire_session(state.session.id, reason: "absolute_timeout", scope: state.scope)

    {:stop, :normal, 1000,
     [{:text, encode(%{type: "error", message: "Remote access session reached its maximum duration."})}],
     %{state | closing_action: :expired}}
  end

  def handle_info(:reauthorize, state) do
    case ensure_current_authority(state) do
      {:ok, state} -> {:ok, schedule_reauth_timer(state)}
      {:error, :permission_revoked} -> stop_for_permission_revoked(state)
    end
  end

  # `start_broker/3` links the broker to the Bandit/ThousandIsland connection,
  # which traps exits and forwards unmatched messages to this handler. An agent
  # close notice arrives before the broker's exit signal. Bandit's stop reply
  # begins the WebSocket close handshake without ending the connection process,
  # so `closing_action` must suppress a second close when that signal arrives.
  # Without a prior notice, the exit must close or fail the stream instead of
  # leaving it open until the idle timeout. The broker-exit cases in
  # remote_access_stream_handler_test.exs cover both paths.
  def handle_info({:EXIT, broker, _reason}, %{broker: broker, closing_action: action} = state)
      when is_pid(broker) and not is_nil(action) do
    {:ok, state}
  end

  def handle_info({:EXIT, broker, reason}, %{broker: broker} = state) when is_pid(broker) do
    stop_for_broker_exit(reason, state)
  end

  # Ash and Task run parts of attach in linked helper processes; their ordinary
  # teardown is not an unknown stream message and must not be logged as one.
  def handle_info({:EXIT, _pid, reason}, state) when reason in [:normal, :shutdown] do
    {:ok, state}
  end

  def handle_info(message, state) do
    log_unknown_stream_message(unknown_info_message_type(message), state, :server_info)
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    _ = cancel_timeout_timers(state)
    maybe_close_desktop_viewers(state, reason)

    if state.broker do
      state.broker_module.close(state.broker, reason)
    end

    if state.session && is_nil(state.closing_action) do
      _ = state.sessions_module.request_close(state.session.id, reason: "browser_disconnected", scope: state.scope)
    end

    :ok
  end

  defp maybe_close_desktop_viewers(%{session: session} = state, reason) when not is_nil(session) do
    if protocol(session) == "rdp" do
      _ =
        state.desktop_webrtc_module.close_all_for_session(session.id,
          scope: state.scope,
          reason: desktop_cleanup_reason(state, reason)
        )
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp maybe_close_desktop_viewers(_state, _reason), do: :ok

  defp desktop_cleanup_reason(%{closing_action: action}, _reason) when not is_nil(action),
    do: "remote_access_stream_#{action}"

  defp desktop_cleanup_reason(_state, reason), do: "remote_access_stream_#{format_close_reason(reason)}"

  defp start_broker(session, message, state) do
    with {:ok, cols} <- optional_terminal_int(Map.get(message, "cols"), @min_terminal_cols, @max_terminal_cols),
         {:ok, rows} <- optional_terminal_int(Map.get(message, "rows"), @min_terminal_rows, @max_terminal_rows),
         {:ok, credential_opts} <- credential_broker_opts(session, message, state) do
      opts =
        [
          cols: cols,
          rows: rows
        ] ++ credential_opts

      state.broker_module.start_link(session, self(), opts)
    end
  end

  defp attach_with_current_authority(ticket, state) do
    with {:ok, %RemoteAccessSession{} = session} <-
           state.sessions_module.attach_with_ticket(ticket,
             session_id: state.session_id,
             scope: state.scope
           ),
         :ok <- ensure_session_owner(session, state.scope),
         {:ok, authorized_state} <- ensure_current_authority(%{state | session: session}) do
      {:ok, session, authorized_state}
    else
      {:error, :permission_revoked} ->
        {:error, :permission_revoked, state}

      {:error, :current_authority_denied} ->
        {:error, :permission_revoked, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_transfer_message(frame, state) do
    %{
      type: "file_transfer",
      session_id: string_value(frame, :session_id) || state.session_id,
      frame_type: string_value(frame, :frame_type),
      payload: file_transfer_payload(frame)
    }
  end

  defp file_transfer_payload(frame) do
    case string_value(frame, :data) do
      nil -> %{}
      "" -> %{}
      data -> decode_json_payload(data)
    end
  end

  defp application_message(frame, state) do
    %{
      type: "application",
      session_id: string_value(frame, :session_id) || state.session_id,
      frame_type: string_value(frame, :frame_type),
      payload: application_payload(frame)
    }
  end

  defp application_payload(frame) do
    frame
    |> string_value(:data)
    |> case do
      nil -> %{}
      "" -> %{}
      data -> decode_json_payload(data)
    end
  end

  defp tcp_message(frame, state) do
    %{
      type: "tcp",
      session_id: string_value(frame, :session_id) || state.session_id,
      frame_type: string_value(frame, :frame_type),
      payload: tcp_payload(frame)
    }
  end

  defp tcp_payload(frame) do
    frame
    |> string_value(:data)
    |> case do
      nil -> %{}
      "" -> %{}
      data -> decode_json_payload(data)
    end
  end

  defp decode_json_payload(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, payload} when is_map(payload) -> payload
      {:ok, payload} -> %{"value" => payload}
      {:error, _reason} -> %{}
    end
  end

  defp credential_broker_opts(session, message, state) do
    credential = normalize_map(Map.get(message, "credential"))

    case {custody_mode(session), protocol(session), credential} do
      {"ssh_certificate", _protocol, credential} when map_size(credential) > 0 ->
        with :ok <- reject_controlled_credential_fields(credential),
             {:ok, credential} <- normalize_certificate_credential(credential),
             attrs = certificate_request_attrs(credential, session),
             {:ok, grant} <-
               RemoteAccessSSHSessionCredentials.build_identity_certificate_grant(
                 scope_actor(state.scope),
                 attrs,
                 idp_claims: scope_identity_claims(state.scope)
               ) do
          {:ok, grant.broker_opts}
        end

      {"ssh_certificate", _protocol, _credential} ->
        {:error, :session_credential_required}

      {"user_present", "rdp", credential} when map_size(credential) > 0 ->
        with :ok <- reject_controlled_credential_fields(credential),
             {:ok, credential} <- normalize_rdp_user_present_credential(credential),
             {:ok, grant} <- rdp_user_present_credential_grant(session, credential, state.scope) do
          {:ok,
           [
             metadata: %{"credential_grant" => grant},
             credential_mode: "user_present"
           ]}
        end

      {"user_present", _protocol, credential} when map_size(credential) > 0 ->
        with :ok <- reject_controlled_credential_fields(credential),
             {:ok, credential} <- normalize_user_present_credential(credential),
             attrs =
               credential
               |> Map.put("session_id", session.id)
               |> Map.put("agent_id", session.agent_id)
               |> Map.put("target", session_target(session)),
             {:ok, grant} <- RemoteAccessSSHSessionCredentials.build_user_present_grant(attrs) do
          {:ok, grant.broker_opts}
        end

      {"user_present", _protocol, _credential} ->
        {:error, :session_credential_required}

      {"centrally_brokered", _protocol, credential} when map_size(credential) > 0 ->
        {:error, :credential_policy_denied}

      {"centrally_brokered", _protocol, _credential} ->
        with {:ok, grant} <-
               state.credential_grant_resolver.build_broker_grant(session,
                 scope: state.scope
               ) do
          {:ok, grant.broker_opts}
        end

      {_mode, _protocol, credential} when map_size(credential) > 0 ->
        {:error, :credential_policy_denied}

      {_mode, _protocol, _credential} ->
        {:ok, []}
    end
  end

  defp normalize_rdp_user_present_credential(credential) do
    with {:ok, username} <- bounded_string(credential, "username", @max_username_bytes),
         {:ok, password} <- bounded_string(credential, "password", @max_password_bytes),
         {:ok, nil} <- optional_bounded_string(credential, "private_key", @max_private_key_bytes),
         {:ok, nil} <- optional_bounded_string(credential, "passphrase", @max_passphrase_bytes) do
      {:ok, %{"username" => username, "password" => password}}
    else
      {:ok, _unsupported_secret} -> {:error, :credential_policy_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rdp_user_present_credential_grant(session, credential, scope) do
    with {:ok, target_id} <- required_metadata_string(session, "desktop_target_id"),
         {:ok, route_id} <- required_session_string(session, :agent_id),
         {:ok, actor_id} <- scope_actor_id(scope) do
      {:ok,
       %{
         "mode" => "memory_user",
         "username" => Map.fetch!(credential, "username"),
         "password" => Map.fetch!(credential, "password"),
         "actor_id" => actor_id,
         "session_id" => session.id,
         "target_id" => target_id,
         "route_id" => route_id
       }}
    end
  end

  defp application_request_payload(message) do
    with {:ok, request_id} <- application_bounded_string(message, "request_id", @max_application_request_id_bytes),
         {:ok, method} <- application_method(message),
         {:ok, path} <- application_path(message),
         {:ok, query} <- application_optional_bounded_string(message, "query", @max_application_query_bytes),
         {:ok, headers} <- application_headers(Map.get(message, "headers")) do
      {:ok,
       %{
         request_id: request_id,
         method: method,
         path: path,
         query: query || "",
         headers: headers
       }}
    end
  end

  defp application_bounded_string(message, key, max_bytes) do
    case application_optional_bounded_string(message, key, max_bytes) do
      {:ok, nil} -> {:error, :invalid_request}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp application_optional_bounded_string(message, key, max_bytes) do
    case string_value(message, key) do
      nil -> {:ok, nil}
      value when byte_size(value) <= max_bytes -> {:ok, value}
      _value -> {:error, :invalid_size}
    end
  end

  defp application_method(%{"method" => method}) when is_binary(method) do
    method =
      method
      |> String.trim()
      |> String.upcase()

    if method in @application_methods do
      {:ok, method}
    else
      {:error, :invalid_request}
    end
  end

  defp application_method(_message), do: {:error, :invalid_request}

  defp application_path(%{"path" => path}) when is_binary(path) and byte_size(path) <= @max_application_path_bytes do
    if safe_application_path?(path), do: {:ok, path}, else: {:error, :invalid_request}
  end

  defp application_path(_message), do: {:error, :invalid_request}

  defp safe_application_path?(path) when is_binary(path) do
    path == String.trim(path) and safe_application_path_segments?(path) and
      case path_unescape(path) do
        {:ok, decoded} -> safe_application_path_segments?(decoded)
        {:error, _reason} -> false
      end
  end

  defp safe_application_path_segments?(path) do
    String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
      not String.contains?(path, ["://", "\\"]) and
      not String.match?(path, ~r/[\x00-\x1F\x7F]/) and
      path
      |> String.split("/")
      |> Enum.all?(&(&1 not in [".", ".."]))
  end

  defp path_unescape(path) do
    if String.match?(path, ~r/%(?![0-9A-Fa-f]{2})/) do
      {:error, :invalid_percent_encoding}
    else
      {:ok, URI.decode(path)}
    end
  end

  defp application_headers(nil), do: {:ok, %{}}

  defp application_headers(headers) when is_map(headers) and map_size(headers) <= @max_application_header_count do
    Enum.reduce_while(headers, {:ok, %{}}, fn {name, values}, {:ok, acc} ->
      with {:ok, name} <- application_header_name(name),
           {:ok, values} <- application_header_values(values) do
        {:cont, {:ok, Map.put(acc, name, values)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp application_headers(_headers), do: {:error, :invalid_request}

  defp application_header_name(name)
       when is_binary(name) and byte_size(name) > 0 and byte_size(name) <= @max_application_header_name_bytes do
    {:ok, name}
  end

  defp application_header_name(_name), do: {:error, :invalid_request}

  defp application_header_values(value) when is_binary(value), do: application_header_values([value])

  defp application_header_values(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_binary(value) and byte_size(value) <= @max_application_header_value_bytes ->
        {:cont, {:ok, [value | acc]}}

      _value, _acc ->
        {:halt, {:error, :invalid_request}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp application_header_values(_values), do: {:error, :invalid_request}

  defp application_data_payload(message) do
    with {:ok, request_id} <- application_bounded_string(message, "request_id", @max_application_request_id_bytes),
         {:ok, sequence} <- bounded_sequence(Map.get(message, "sequence"), @max_application_sequence),
         {:ok, data} <-
           base64_data(
             Map.get(message, "data"),
             @max_application_data_frame_encoded_bytes,
             @max_application_data_frame_bytes
           ),
         {:ok, eof} <- optional_boolean(Map.get(message, "eof")) do
      {:ok,
       %{
         request_id: request_id,
         direction: "request",
         sequence: sequence,
         data: data,
         eof: eof
       }}
    end
  end

  defp tcp_data_payload(message) do
    with {:ok, connection_id} <- application_bounded_string(message, "connection_id", @max_tcp_connection_id_bytes),
         {:ok, sequence} <- bounded_sequence(Map.get(message, "sequence"), @max_tcp_sequence),
         {:ok, data} <-
           base64_data(Map.get(message, "data"), @max_tcp_data_frame_encoded_bytes, @max_tcp_data_frame_bytes),
         {:ok, eof} <- optional_boolean(Map.get(message, "eof")) do
      {:ok,
       %{
         connection_id: connection_id,
         direction: "client",
         sequence: sequence,
         data: data,
         eof: eof
       }}
    end
  end

  defp bounded_sequence(sequence, max_sequence) when is_integer(sequence) and sequence >= 1 and sequence <= max_sequence,
    do: {:ok, sequence}

  defp bounded_sequence(_sequence, _max_sequence), do: {:error, :invalid_request}

  defp base64_data(data, max_encoded_bytes, max_decoded_bytes)
       when is_binary(data) and byte_size(data) <= max_encoded_bytes do
    case Base.decode64(data) do
      {:ok, decoded} when byte_size(decoded) <= max_decoded_bytes -> {:ok, data}
      {:ok, _decoded} -> {:error, :invalid_data_size}
      :error -> {:error, :invalid_request}
    end
  end

  defp base64_data(_data, _max_encoded_bytes, _max_decoded_bytes), do: {:error, :invalid_request}

  defp optional_boolean(nil), do: {:ok, false}
  defp optional_boolean(value) when is_boolean(value), do: {:ok, value}
  defp optional_boolean(_value), do: {:error, :invalid_request}

  defp normalize_certificate_credential(credential) do
    with {:ok, private_key} <- bounded_string(credential, "private_key", @max_private_key_bytes),
         {:ok, public_key} <- bounded_string(credential, "public_key", @max_public_key_bytes),
         {:ok, passphrase} <- optional_bounded_string(credential, "passphrase", @max_passphrase_bytes),
         {:ok, username} <- bounded_string(credential, "username", @max_username_bytes) do
      {:ok,
       drop_nil_values(%{
         "private_key" => private_key,
         "public_key" => public_key,
         "passphrase" => passphrase,
         "username" => username
       })}
    end
  end

  defp normalize_user_present_credential(credential) do
    with {:ok, username} <- bounded_string(credential, "username", @max_username_bytes),
         {:ok, private_key} <- optional_bounded_string(credential, "private_key", @max_private_key_bytes),
         {:ok, password} <- optional_bounded_string(credential, "password", @max_password_bytes),
         {:ok, passphrase} <- optional_bounded_string(credential, "passphrase", @max_passphrase_bytes),
         :ok <- require_one_session_secret(private_key, password) do
      {:ok,
       drop_nil_values(%{
         "username" => username,
         "private_key" => private_key,
         "password" => password,
         "passphrase" => passphrase
       })}
    end
  end

  defp reject_controlled_credential_fields(credential) do
    if Enum.any?(@credential_controlled_keys, &credential_key_present?(credential, &1)) do
      {:error, :credential_policy_denied}
    else
      :ok
    end
  end

  defp credential_key_present?(credential, key) do
    Map.has_key?(credential, key) or
      case safe_existing_atom(key) do
        nil -> false
        atom_key -> Map.has_key?(credential, atom_key)
      end
  end

  defp bounded_string(credential, key, max_bytes) do
    case optional_bounded_string(credential, key, max_bytes) do
      {:ok, nil} -> {:error, :session_credential_required}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_bounded_string(credential, key, max_bytes) do
    case string_value(credential, key) do
      nil ->
        {:ok, nil}

      value ->
        if byte_size(value) <= max_bytes do
          {:ok, value}
        else
          {:error, :credential_policy_denied}
        end
    end
  end

  defp require_one_session_secret(private_key, password) do
    if is_nil(private_key) and is_nil(password) do
      {:error, :session_credential_required}
    else
      :ok
    end
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  defp certificate_request_attrs(credential, session) do
    %{
      "session_id" => session.id,
      "agent_id" => session.agent_id,
      "gateway_id" => session.gateway_id,
      "public_key" => string_value(credential, "public_key"),
      "private_key" => string_value(credential, "private_key"),
      "passphrase" => string_value(credential, "passphrase"),
      "username" => string_value(credential, "username"),
      "target" => session_target(session),
      "accounts" => metadata_value(session, "ssh_accounts"),
      "principal_mappings" => metadata_value(session, "ssh_principal_mappings") || [],
      "ttl_seconds" => metadata_value(session, "ssh_certificate_ttl_seconds")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  defp custody_mode(%{credential_custody_mode: value}) when is_atom(value), do: Atom.to_string(value)
  defp custody_mode(%{credential_custody_mode: value}) when is_binary(value), do: value
  defp custody_mode(_session), do: "none"

  defp session_target(session) do
    %{
      "device_uid" => session.device_uid,
      "host" => session.target_host,
      "port" => session.target_port
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: %{}

  defp scope_actor_id(scope) do
    case scope_actor(scope) do
      %{id: id} when is_binary(id) and id != "" -> {:ok, id}
      %{"id" => id} when is_binary(id) and id != "" -> {:ok, id}
      _actor -> {:error, :invalid_request}
    end
  end

  defp scope_actor_id_or_unknown(scope) do
    case scope_actor_id(scope) do
      {:ok, actor_id} -> actor_id
      {:error, _reason} -> "unknown"
    end
  end

  defp ensure_session_owner(%RemoteAccessSession{requested_by: requested_by}, scope) do
    with {:ok, actor_id} <- scope_actor_id(scope),
         owner_id when is_binary(owner_id) <- normalize_owner_id(requested_by),
         true <- actor_id == owner_id do
      :ok
    else
      _mismatch -> {:error, :invalid_or_expired_ticket}
    end
  end

  defp normalize_owner_id(nil), do: nil
  defp normalize_owner_id(id) when is_binary(id), do: id
  defp normalize_owner_id(id), do: to_string(id)

  defp record_desktop_activity(message, state) do
    now_ms = System.monotonic_time(:millisecond)

    with :ok <- ensure_session_id(message, state.session_id),
         true <- protocol(state.session) == "rdp" do
      if activity_persist_due?(state.last_activity_persisted_at_ms, now_ms) do
        case state.sessions_module.record_activity(state.session_id, scope: state.scope) do
          {:ok, _session} ->
            {:ok,
             state
             |> Map.put(:last_activity_persisted_at_ms, now_ms)
             |> reset_idle_timer()}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:ok, reset_idle_timer(state)}
      end
    else
      false -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp activity_persist_due?(nil, _now_ms), do: true

  defp activity_persist_due?(last_ms, now_ms) when is_integer(last_ms) and is_integer(now_ms),
    do: now_ms - last_ms >= @desktop_activity_persist_interval_ms

  defp log_unknown_stream_message(message_type, state, source) do
    metadata = %{
      topic: "remote_access:#{state.session_id}",
      session_id: state.session_id,
      actor_id: scope_actor_id_or_unknown(state.scope),
      message_type: message_type,
      source: source
    }

    Logger.warning("Ignored unknown remote access stream message", Map.to_list(metadata))

    :telemetry.execute(
      [:serviceradar, :remote_access, :stream, :unknown_message],
      %{count: 1},
      metadata
    )
  end

  defp unknown_browser_message_type({:ok, %{"type" => type}}) when is_binary(type) do
    normalize_message_type(type)
  end

  defp unknown_browser_message_type({:ok, %{"type" => _type}}), do: "non_string_type"
  defp unknown_browser_message_type({:ok, _message}), do: "missing_type"
  defp unknown_browser_message_type({:error, _reason}), do: "invalid_json"

  defp unknown_info_message_type(message) when is_tuple(message) and tuple_size(message) > 0 do
    message
    |> elem(0)
    |> normalize_message_type()
  end

  defp unknown_info_message_type(message), do: normalize_message_type(message)

  defp normalize_message_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_message_type(type) when is_binary(type), do: String.slice(type, 0, 64)
  defp normalize_message_type(type) when is_tuple(type), do: "tuple"
  defp normalize_message_type(type) when is_map(type), do: "map"
  defp normalize_message_type(type) when is_list(type), do: "list"
  defp normalize_message_type(type) when is_integer(type), do: "integer"
  defp normalize_message_type(type) when is_float(type), do: "float"
  defp normalize_message_type(type) when is_boolean(type), do: "boolean"
  defp normalize_message_type(type) when is_pid(type), do: "pid"
  defp normalize_message_type(type) when is_reference(type), do: "reference"
  defp normalize_message_type(type) when is_function(type), do: "function"
  defp normalize_message_type(_type), do: "unknown"

  defp scope_identity_claims(%{identity_claims: claims}) when is_map(claims), do: claims
  defp scope_identity_claims(%{"identity_claims" => claims}) when is_map(claims), do: claims
  defp scope_identity_claims(_scope), do: %{}

  defp metadata_value(%{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, safe_existing_atom(key))
  end

  defp metadata_value(_session, _key), do: nil

  defp required_metadata_string(session, key) do
    case metadata_value(session, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :invalid_request}
    end
  end

  defp required_session_string(session, key) do
    case Map.get(session, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :invalid_request}
    end
  end

  defp protocol(%{protocol: value}) when is_atom(value), do: Atom.to_string(value)
  defp protocol(%{protocol: value}) when is_binary(value), do: value
  defp protocol(_session), do: "ssh"

  defp string_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, safe_existing_atom(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp safe_existing_atom(key) when is_atom(key), do: key

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp stop_for_broker_exit(reason, state) do
    if orderly_exit?(reason) do
      _ =
        state.sessions_module.close_session(state.session.id,
          reason: "broker_stopped",
          scope: state.scope
        )

      {:stop, :normal, 1000, [{:text, encode(%{type: "close", reason: "closed"})}], %{state | closing_action: :closed}}
    else
      stop_for_broker_error(reason, state)
    end
  end

  defp orderly_exit?(:normal), do: true
  defp orderly_exit?(:shutdown), do: true
  defp orderly_exit?({:shutdown, _details}), do: true
  defp orderly_exit?(_reason), do: false

  # An unavailable broker may have queued its close notice while this browser
  # frame was in flight. Let handle_info/2 deliver that reason, or handle the
  # linked broker's exit if no notice exists, instead of replacing the reason
  # with a generic "stream failed".
  defp handle_broker_error(:broker_unavailable, state), do: {:ok, state}
  defp handle_broker_error(reason, state), do: stop_for_broker_error(reason, state)

  defp stop_for_broker_error(reason, state) do
    _ = state.sessions_module.fail_session(state.session_id, reason, scope: state.scope)

    {:stop, :normal, 1011, [{:text, encode(%{type: "error", message: "Remote access stream failed."})}],
     %{state | closing_action: :failed}}
  end

  defp ensure_current_authority(%{session: nil} = state), do: {:ok, state}

  defp ensure_current_authority(state) do
    permission = permission_for_session(state.session)

    case state.authorization_module.authorize_current(state.scope, [permission]) do
      {:ok, refreshed_scope} -> {:ok, %{state | scope: refreshed_scope}}
      _ -> {:error, :permission_revoked}
    end
  end

  defp with_current_authority(state, authorized_callback) do
    case ensure_current_authority(state) do
      {:ok, state} -> authorized_callback.(state)
      {:error, :permission_revoked} -> stop_for_permission_revoked(state)
    end
  end

  defp permission_for_session(session) do
    case protocol(session) do
      "rdp" -> "devices.remote_access.rdp.open"
      _protocol -> "devices.remote_access.ssh.open"
    end
  end

  defp stop_for_permission_revoked(state) do
    _ =
      state.sessions_module.request_close(state.session_id,
        reason: "permission_revoked",
        scope: state.scope
      )

    {:stop, :normal, 1008, [{:text, encode(%{type: "error", message: "Remote access permission was revoked."})}],
     %{state | closing_action: :revoked}}
  end

  defp schedule_timeout_timers(state, session) do
    %{
      state
      | idle_timer: schedule_timeout(:idle_timeout, session.idle_timeout_seconds),
        absolute_timer: schedule_timeout(:absolute_timeout, session.absolute_timeout_seconds)
    }
  end

  defp reset_idle_timer(%{session: nil} = state), do: state

  defp reset_idle_timer(state) do
    _ = cancel_timer(state.idle_timer)
    %{state | idle_timer: schedule_timeout(:idle_timeout, state.session.idle_timeout_seconds)}
  end

  defp schedule_reauth_timer(state) do
    _ = cancel_timer(state.reauth_timer)
    %{state | reauth_timer: schedule_reauth_timeout(state.reauth_interval_ms)}
  end

  defp schedule_reauth_timeout(milliseconds) when is_integer(milliseconds) and milliseconds > 0 do
    Process.send_after(self(), :reauthorize, milliseconds)
  end

  defp schedule_reauth_timeout(_milliseconds), do: nil

  defp schedule_timeout(message, seconds) when is_integer(seconds) and seconds > 0 do
    Process.send_after(self(), message, seconds * 1000)
  end

  defp schedule_timeout(_message, _seconds), do: nil

  defp cancel_timeout_timers(state) do
    _ = cancel_timer(state.idle_timer)
    _ = cancel_timer(state.absolute_timer)
    _ = cancel_timer(state.reauth_timer)
    %{state | idle_timer: nil, absolute_timer: nil, reauth_timer: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp ensure_session_id(%{"session_id" => browser_session_id}, session_id) do
    if to_string(browser_session_id) == to_string(session_id), do: :ok, else: {:error, :session_mismatch}
  end

  defp ensure_session_id(_message, _session_id), do: :ok

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_required_field}, else: {:ok, value}

      _value ->
        {:error, :missing_required_field}
    end
  end

  defp decode_json(data) when is_binary(data), do: Jason.decode(data)

  defp file_transfer_data_payload(message) do
    with {:ok, transfer_id} <- required_string(message, "transfer_id"),
         {:ok, sequence} <- positive_integer(Map.get(message, "sequence")),
         {:ok, offset} <- nonnegative_integer(Map.get(message, "offset")),
         {:ok, data} <- file_transfer_chunk(Map.get(message, "data")),
         {:ok, eof} <- boolean_value(Map.get(message, "eof", false)) do
      {:ok,
       %{
         transfer_id: transfer_id,
         sequence: sequence,
         offset: offset,
         data: Base.encode64(data),
         eof: eof
       }}
    end
  end

  defp file_transfer_chunk(nil), do: {:ok, ""}

  defp file_transfer_chunk(encoded) when is_binary(encoded) do
    if byte_size(encoded) > @max_file_transfer_chunk_encoded_bytes do
      {:error, :invalid_size}
    else
      case Base.decode64(encoded) do
        {:ok, decoded} when byte_size(decoded) <= @max_file_transfer_chunk_bytes -> {:ok, decoded}
        {:ok, _decoded} -> {:error, :invalid_size}
        :error -> {:error, :invalid_request}
      end
    end
  end

  defp file_transfer_chunk(_value), do: {:error, :invalid_request}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> positive_integer(int)
      _ -> {:error, :invalid_request}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_request}

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> nonnegative_integer(int)
      _ -> {:error, :invalid_request}
    end
  end

  defp nonnegative_integer(_value), do: {:error, :invalid_request}

  defp boolean_value(value) when is_boolean(value), do: {:ok, value}
  defp boolean_value("true"), do: {:ok, true}
  defp boolean_value("false"), do: {:ok, false}
  defp boolean_value(_value), do: {:error, :invalid_request}

  defp decode_base64(value) when byte_size(value) <= @max_browser_data_frame_encoded_bytes do
    case Base.decode64(value) do
      {:ok, decoded} when byte_size(decoded) <= @max_browser_data_frame_bytes -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_data_size}
      :error -> {:error, :invalid_data}
    end
  end

  defp decode_base64(_value), do: {:error, :invalid_data_size}

  defp encode(payload), do: Jason.encode!(payload)

  # A host-key verification failure is the one close reason the browser can act
  # on, so it crosses the boundary as structured fields alongside the reason
  # text. Everything here is derived from the reason already being sent: the
  # target address the console already displays and the target's public host-key
  # fingerprint, which is the value an operator is meant to compare out of band.
  defp close_message(close_reason) do
    case RemoteAccessHostKeyFailure.classify(close_reason) do
      nil -> %{type: "close", reason: close_reason}
      host_key -> %{type: "close", reason: close_reason, host_key: host_key}
    end
  end

  defp format_close_reason(nil), do: "closed"
  defp format_close_reason(reason) when is_binary(reason), do: reason
  defp format_close_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_close_reason(reason), do: inspect(reason)

  defp optional_terminal_int(nil, _min, _max), do: {:ok, nil}

  defp optional_terminal_int(value, min, max) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      _present -> terminal_int(value, min, max)
    end
  end

  defp optional_terminal_int(value, min, max), do: terminal_int(value, min, max)

  defp terminal_int(value, min, max) when is_integer(value) do
    if value >= min and value <= max do
      {:ok, value}
    else
      {:error, :invalid_size}
    end
  end

  defp terminal_int(value, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> terminal_int(int, min, max)
      _ -> {:error, :invalid_size}
    end
  end

  defp terminal_int(_value, _min, _max), do: {:error, :invalid_size}
end
