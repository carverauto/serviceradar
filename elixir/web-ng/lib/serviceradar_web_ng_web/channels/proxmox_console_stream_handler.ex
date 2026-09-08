defmodule ServiceRadarWebNGWeb.Channels.ProxmoxConsoleStreamHandler do
  @moduledoc """
  Browser-facing WebSock handler for Proxmox console streams.

  The wire format intentionally mirrors Scion's webpty JSON messages:
  `%{"type" => "data", "data" => base64}` and `%{"type" => "resize", ...}`.
  Browsers first send `%{"type" => "attach", "ticket" => ticket}` so the
  short-lived ticket never appears in URLs or logs.
  """

  @behaviour WebSock

  alias ServiceRadar.Edge.ProxmoxConsoleBroker
  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadar.Edge.ProxmoxConsoleSessions

  require Logger

  @min_terminal_cols 1
  @max_terminal_cols 500
  @min_terminal_rows 1
  @max_terminal_rows 200
  @max_browser_data_frame_bytes 65_536
  @max_browser_data_frame_encoded_bytes div(@max_browser_data_frame_bytes + 2, 3) * 4
  @console_permissions ["devices.console.open", "devices.console.credentials.use"]
  @default_reauth_interval_ms 30_000

  @impl true
  def init(options) do
    {:ok,
     %{
       session_id: Keyword.fetch!(options, :session_id),
       scope: Keyword.fetch!(options, :scope),
       broker_module: Keyword.get(options, :broker_module, ProxmoxConsoleBroker),
       sessions_module: Keyword.get(options, :sessions_module, ProxmoxConsoleSessions),
       authorization_module: Keyword.get(options, :authorization_module, ServiceRadarWebNG.RBAC),
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
         {:ok, %ProxmoxConsoleSession{} = session, state} <-
           attach_with_current_authority(ticket, state),
         {:ok, broker} <- start_broker(session, message, state) do
      state =
        state
        |> cancel_timeout_timers()
        |> schedule_timeout_timers(session)
        |> schedule_reauth_timer()

      {:push, {:text, encode(%{type: "ready", session_id: session.id})},
       %{state | attached?: true, session: session, broker: broker}}
    else
      {:error, :console_broker_unavailable} ->
        _ = state.sessions_module.fail_session(state.session_id, :console_broker_unavailable, scope: state.scope)

        {:stop, :normal, 1011,
         [{:text, encode(%{type: "error", message: "Proxmox console broker is not available on the edge agent yet."})}],
         state}

      {:error, :invalid_size} ->
        _ = state.sessions_module.fail_session(state.session_id, :invalid_size, scope: state.scope)

        {:stop, :normal, 1008, [{:text, encode(%{type: "error", message: "Invalid console terminal dimensions."})}],
         state}

      {:error, :permission_revoked, denied_state} ->
        stop_for_permission_revoked(denied_state)

      {:error, reason} ->
        Logger.warning("Proxmox console websocket attach rejected",
          session_id: state.session_id,
          reason: inspect(reason)
        )

        {:stop, :normal, 1008, [{:text, encode(%{type: "error", message: "Invalid or expired console ticket."})}], state}
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
    case ensure_current_authority(state) do
      {:ok, state} -> {:ok, state}
      {:error, :permission_revoked} -> stop_for_permission_revoked(state)
    end
  end

  @impl true
  def handle_info({:proxmox_console_data, payload}, state) when is_binary(payload) do
    with_current_authority(state, fn state ->
      {:push, {:text, encode(%{type: "data", data: Base.encode64(payload)})}, reset_idle_timer(state)}
    end)
  end

  def handle_info({:proxmox_console_closed, reason}, state) do
    with_current_authority(state, fn state ->
      _ =
        state.sessions_module.close_session(state.session.id,
          reason: format_close_reason(reason),
          scope: state.scope
        )

      {:stop, :normal, 1000, [{:text, encode(%{type: "close", reason: format_close_reason(reason)})}],
       %{state | closing_action: :closed}}
    end)
  end

  def handle_info(:idle_timeout, state) do
    _ = state.sessions_module.expire_session(state.session.id, reason: "idle_timeout", scope: state.scope)

    {:stop, :normal, 1000, [{:text, encode(%{type: "error", message: "Console session closed after idle timeout."})}],
     %{state | closing_action: :expired}}
  end

  def handle_info(:absolute_timeout, state) do
    _ = state.sessions_module.expire_session(state.session.id, reason: "absolute_timeout", scope: state.scope)

    {:stop, :normal, 1000, [{:text, encode(%{type: "error", message: "Console session reached its maximum duration."})}],
     %{state | closing_action: :expired}}
  end

  def handle_info(:reauthorize, state) do
    case ensure_current_authority(state) do
      {:ok, state} -> {:ok, schedule_reauth_timer(state)}
      {:error, :permission_revoked} -> stop_for_permission_revoked(state)
    end
  end

  def handle_info(message, state) do
    Logger.debug("Ignoring unexpected Proxmox console websocket message: #{inspect(message)}")
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
         {:ok, rows} <- optional_terminal_int(Map.get(message, "rows"), @min_terminal_rows, @max_terminal_rows) do
      opts = [
        cols: cols,
        rows: rows
      ]

      state.broker_module.start_link(session, self(), opts)
    end
  end

  defp attach_with_current_authority(ticket, state) do
    case ensure_current_authority(state) do
      {:ok, current_state} ->
        with {:ok, %ProxmoxConsoleSession{} = session} <-
               current_state.sessions_module.attach_with_ticket(ticket,
                 session_id: current_state.session_id,
                 scope: current_state.scope
               ),
             {:ok, authorized_state} <-
               ensure_current_authority(%{current_state | session: session}) do
          {:ok, session, authorized_state}
        else
          {:error, :permission_revoked} -> {:error, :permission_revoked, current_state}
          {:error, reason} -> {:error, reason}
        end

      {:error, :permission_revoked} ->
        {:error, :forbidden}
    end
  end

  defp stop_for_broker_error(reason, state) do
    _ = state.sessions_module.fail_session(state.session_id, reason, scope: state.scope)

    {:stop, :normal, 1011, [{:text, encode(%{type: "error", message: "Proxmox console stream failed."})}],
     %{state | closing_action: :failed}}
  end

  defp ensure_current_authority(state) do
    case state.authorization_module.authorize_current(state.scope, @console_permissions) do
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

  defp stop_for_permission_revoked(state) do
    _ =
      state.sessions_module.request_close(state.session_id,
        reason: "permission_revoked",
        scope: state.scope
      )

    {:stop, :normal, 1008, [{:text, encode(%{type: "error", message: "Proxmox console permission was revoked."})}],
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

  defp schedule_reauth_timer(state) do
    _ = cancel_timer(state.reauth_timer)
    %{state | reauth_timer: schedule_reauth_timeout(state.reauth_interval_ms)}
  end

  defp schedule_reauth_timeout(milliseconds) when is_integer(milliseconds) and milliseconds > 0 do
    Process.send_after(self(), :reauthorize, milliseconds)
  end

  defp schedule_reauth_timeout(_milliseconds), do: nil

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
