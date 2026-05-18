defmodule ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandler do
  @moduledoc """
  Browser-facing WebSock handler for generic remote-access streams.

  The browser first sends an attach frame containing the short-lived ticket.
  After attach, only terminal/protocol bytes, resize requests, ready, close, and
  sanitized error messages cross the browser boundary.
  """

  @behaviour WebSock

  alias ServiceRadar.Edge.RemoteAccessBroker
  alias ServiceRadar.Edge.RemoteAccessCentralCredentialGrants
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSessions
  alias ServiceRadar.Edge.RemoteAccessSSHSessionCredentials

  require Logger

  @min_terminal_cols 1
  @max_terminal_cols 500
  @min_terminal_rows 1
  @max_terminal_rows 200
  @max_browser_data_frame_bytes 65_536
  @max_browser_data_frame_encoded_bytes div(@max_browser_data_frame_bytes + 2, 3) * 4
  @max_file_transfer_chunk_bytes 65_536
  @max_file_transfer_chunk_encoded_bytes div(@max_file_transfer_chunk_bytes + 2, 3) * 4
  @max_username_bytes 128
  @max_private_key_bytes 65_536
  @max_public_key_bytes 16_384
  @max_password_bytes 4_096
  @max_passphrase_bytes 4_096
  @max_principal_bytes 128
  @max_requested_principals 16
  @default_reauth_interval_ms 30_000
  @credential_controlled_keys ~w(
    agent_id
    allowed_principals
    claims
    credential_mode
    gateway_id
    idp_claims
    principal_mappings
    session_id
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
       authorization_module: Keyword.get(options, :authorization_module, ServiceRadar.Identity.RBAC),
       reauth_interval_ms: Keyword.get(options, :reauth_interval_ms, @default_reauth_interval_ms),
       broker: nil,
       session: nil,
       attached?: false,
       idle_timer: nil,
       absolute_timer: nil,
       reauth_timer: nil,
       closing_action: nil
     }}
  end

  @impl true
  def handle_in({data, [opcode: :text]}, %{attached?: false} = state) do
    with {:ok, %{"type" => "attach"} = message} <- decode_json(data),
         {:ok, ticket} <- required_string(message, "ticket"),
         :ok <- ensure_session_id(message, state.session_id),
         {:ok, %RemoteAccessSession{} = session} <-
           state.sessions_module.attach_with_ticket(ticket,
             session_id: state.session_id,
             scope: state.scope
           ),
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
    case ensure_authorized(state) do
      :ok ->
        case decode_json(data) do
          {:ok, %{"type" => "data", "data" => encoded}} when is_binary(encoded) ->
            with {:ok, payload} <- decode_base64(encoded),
                 :ok <- state.broker_module.send_input(state.broker, payload) do
              {:ok, reset_idle_timer(state)}
            else
              {:error, reason} -> stop_for_broker_error(reason, state)
            end

          {:ok, %{"type" => "resize", "cols" => cols, "rows" => rows}} ->
            with {:ok, cols} <- terminal_int(cols, @min_terminal_cols, @max_terminal_cols),
                 {:ok, rows} <- terminal_int(rows, @min_terminal_rows, @max_terminal_rows),
                 :ok <- state.broker_module.resize(state.broker, cols, rows) do
              {:ok, reset_idle_timer(state)}
            else
              {:error, reason} -> stop_for_broker_error(reason, state)
            end

          {:ok, %{"type" => "file_transfer_data"} = message} ->
            with {:ok, payload} <- file_transfer_data_payload(message),
                 :ok <- state.broker_module.send_file_transfer_data(state.broker, payload) do
              {:ok, reset_idle_timer(state)}
            else
              {:error, reason} -> stop_for_broker_error(reason, state)
            end

          {:ok, %{"type" => "attach"}} ->
            {:ok, state}

          _other ->
            {:ok, state}
        end

      {:error, :permission_revoked} ->
        stop_for_permission_revoked(state)
    end
  end

  def handle_in({_data, [opcode: :binary]}, state) do
    case ensure_authorized(state) do
      :ok -> {:ok, state}
      {:error, :permission_revoked} -> stop_for_permission_revoked(state)
    end
  end

  @impl true
  def handle_info({:remote_access_ready, session_id}, state) do
    {:push, {:text, encode(%{type: "adapter_ready", session_id: session_id})}, state}
  end

  def handle_info({:remote_access_data, payload}, state) when is_binary(payload) do
    {:push, {:text, encode(%{type: "data", data: Base.encode64(payload)})}, reset_idle_timer(state)}
  end

  def handle_info({:remote_access_file_transfer_frame, frame}, state) when is_map(frame) do
    {:push, {:text, encode(file_transfer_message(frame, state))}, reset_idle_timer(state)}
  end

  def handle_info({:remote_access_closed, reason}, state) do
    _ =
      state.sessions_module.close_session(state.session.id,
        reason: format_close_reason(reason),
        scope: state.scope
      )

    {:stop, :normal, 1000, [{:text, encode(%{type: "close", reason: format_close_reason(reason)})}],
     %{state | closing_action: :closed}}
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
    case ensure_authorized(state) do
      :ok -> {:ok, schedule_reauth_timer(state)}
      {:error, :permission_revoked} -> stop_for_permission_revoked(state)
    end
  end

  def handle_info(message, state) do
    Logger.debug("Ignoring unexpected remote access websocket message: #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    _ = cancel_timeout_timers(state)

    if state.broker do
      state.broker_module.close(state.broker, reason)
    end

    if state.session && is_nil(state.closing_action) do
      _ = state.sessions_module.request_close(state.session.id, reason: "browser_disconnected", scope: state.scope)
    end

    :ok
  end

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

  defp normalize_certificate_credential(credential) do
    with {:ok, private_key} <- bounded_string(credential, "private_key", @max_private_key_bytes),
         {:ok, public_key} <- bounded_string(credential, "public_key", @max_public_key_bytes),
         {:ok, passphrase} <- optional_bounded_string(credential, "passphrase", @max_passphrase_bytes),
         {:ok, username} <- optional_bounded_string(credential, "username", @max_username_bytes),
         {:ok, requested_principals} <- normalize_requested_principals(credential) do
      {:ok,
       drop_nil_values(%{
         "private_key" => private_key,
         "public_key" => public_key,
         "passphrase" => passphrase,
         "username" => username,
         "requested_principals" => requested_principals
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

  defp normalize_requested_principals(credential) do
    principals =
      list_value(credential, "requested_principals") ||
        list_value(credential, "principals") ||
        username_as_principal(credential) ||
        []

    principals =
      principals
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      length(principals) > @max_requested_principals ->
        {:error, :credential_policy_denied}

      Enum.any?(principals, &(byte_size(&1) > @max_principal_bytes)) ->
        {:error, :credential_policy_denied}

      true ->
        {:ok, principals}
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
      "target" => session_target(session),
      "principal_mappings" => metadata_value(session, "ssh_principal_mappings") || [],
      "allowed_principals" => metadata_value(session, "ssh_allowed_principals"),
      "requested_principals" =>
        list_value(credential, "requested_principals") ||
          list_value(credential, "principals") ||
          username_as_principal(credential),
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

  defp list_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, safe_existing_atom(key)) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      value when is_binary(value) -> [value]
      _ -> nil
    end
  end

  defp username_as_principal(credential) do
    case string_value(credential, "username") do
      nil -> nil
      username -> [username]
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

  defp stop_for_broker_error(reason, state) do
    _ = state.sessions_module.fail_session(state.session_id, reason, scope: state.scope)

    {:stop, :normal, 1011, [{:text, encode(%{type: "error", message: "Remote access stream failed."})}],
     %{state | closing_action: :failed}}
  end

  defp ensure_authorized(%{session: nil}), do: :ok

  defp ensure_authorized(state) do
    user = scope_actor(state.scope)
    permission = permission_for_session(state.session)
    _ = clear_authorization_process_cache(state.authorization_module)

    if state.authorization_module.has_permission?(user, permission) do
      :ok
    else
      {:error, :permission_revoked}
    end
  end

  defp permission_for_session(session) do
    case protocol(session) do
      "rdp" -> "devices.remote_access.rdp.open"
      _protocol -> "devices.remote_access.ssh.open"
    end
  end

  defp clear_authorization_process_cache(module) do
    if function_exported?(module, :clear_process_cache, 0), do: module.clear_process_cache()
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
