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

  @impl true
  def init(options) do
    {:ok,
     %{
       session_id: Keyword.fetch!(options, :session_id),
       scope: Keyword.fetch!(options, :scope),
       broker_module: Keyword.get(options, :broker_module, ProxmoxConsoleBroker),
       broker: nil,
       session: nil,
       attached?: false
     }}
  end

  @impl true
  def handle_in({data, [opcode: :text]}, %{attached?: false} = state) do
    with {:ok, %{"type" => "attach"} = message} <- decode_json(data),
         {:ok, ticket} <- required_string(message, "ticket"),
         :ok <- ensure_session_id(message, state.session_id),
         {:ok, %ProxmoxConsoleSession{} = session} <-
           ProxmoxConsoleSessions.attach_with_ticket(ticket,
             session_id: state.session_id,
             scope: state.scope
           ),
         {:ok, broker} <- start_broker(session, message, state) do
      {:push, {:text, encode(%{type: "ready", session_id: session.id})},
       %{state | attached?: true, session: session, broker: broker}}
    else
      {:error, :console_broker_unavailable} ->
        _ = ProxmoxConsoleSessions.fail_session(state.session_id, :console_broker_unavailable, scope: state.scope)

        {:stop, :normal, 1011,
         [{:text, encode(%{type: "error", message: "Proxmox console broker is not available on the edge agent yet."})}],
         state}

      {:error, reason} ->
        Logger.warning("Proxmox console websocket attach rejected",
          session_id: state.session_id,
          reason: inspect(reason)
        )

        {:stop, :normal, 1008, [{:text, encode(%{type: "error", message: "Invalid or expired console ticket."})}], state}
    end
  end

  def handle_in({data, [opcode: :text]}, state) do
    case decode_json(data) do
      {:ok, %{"type" => "data", "data" => encoded}} when is_binary(encoded) ->
        with {:ok, payload} <- decode_base64(encoded),
             :ok <- state.broker_module.send_input(state.broker, payload) do
          {:ok, state}
        else
          {:error, reason} -> stop_for_broker_error(reason, state)
        end

      {:ok, %{"type" => "resize", "cols" => cols, "rows" => rows}} ->
        with {:ok, cols} <- positive_int(cols),
             {:ok, rows} <- positive_int(rows),
             :ok <- state.broker_module.resize(state.broker, cols, rows) do
          {:ok, state}
        else
          {:error, reason} -> stop_for_broker_error(reason, state)
        end

      {:ok, %{"type" => "attach"}} ->
        {:ok, state}

      _other ->
        {:ok, state}
    end
  end

  def handle_in({_data, [opcode: :binary]}, state), do: {:ok, state}

  @impl true
  def handle_info({:proxmox_console_data, payload}, state) when is_binary(payload) do
    {:push, {:text, encode(%{type: "data", data: Base.encode64(payload)})}, state}
  end

  def handle_info({:proxmox_console_closed, reason}, state) do
    {:stop, :normal, 1000, [{:text, encode(%{type: "close", reason: inspect(reason)})}], state}
  end

  def handle_info(message, state) do
    Logger.debug("Ignoring unexpected Proxmox console websocket message: #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.broker do
      state.broker_module.close(state.broker, reason)
    end

    if state.session do
      _ = ProxmoxConsoleSessions.request_close(state.session.id, reason: "browser_disconnected", scope: state.scope)
    end

    :ok
  end

  defp start_broker(session, message, state) do
    opts = [
      cols: message |> Map.get("cols") |> positive_int_value(),
      rows: message |> Map.get("rows") |> positive_int_value()
    ]

    state.broker_module.start_link(session, self(), opts)
  end

  defp stop_for_broker_error(reason, state) do
    _ = ProxmoxConsoleSessions.fail_session(state.session_id, reason, scope: state.scope)

    {:stop, :normal, 1011, [{:text, encode(%{type: "error", message: "Proxmox console stream failed."})}], state}
  end

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

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_data}
    end
  end

  defp encode(payload), do: Jason.encode!(payload)

  defp positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_size}
    end
  end

  defp positive_int(_value), do: {:error, :invalid_size}

  defp positive_int_value(value) do
    case positive_int(value) do
      {:ok, int} -> int
      {:error, _reason} -> nil
    end
  end
end
