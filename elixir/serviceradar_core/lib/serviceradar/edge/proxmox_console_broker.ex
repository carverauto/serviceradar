defmodule ServiceRadar.Edge.ProxmoxConsoleBroker do
  @moduledoc """
  Broker boundary for Proxmox browser console byte streams.

  The browser-facing broker runs in web-ng/core-elx and sends plain frame maps to
  the agent gateway over the ERTS process registry. The agent gateway is the only
  Elixir process that turns those maps into protobuf frames for the agent gRPC
  control stream.
  """

  use GenServer

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.ProxmoxConsolePubSub

  @callback start_link(map(), pid(), keyword()) :: GenServer.on_start()
  @callback send_input(pid(), binary()) :: :ok | {:error, term()}
  @callback resize(pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  @callback close(pid(), term()) :: :ok

  def start_link(session, owner, opts \\ []) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {session, owner, opts})
  end

  def send_input(pid, data) when is_pid(pid) and is_binary(data) do
    GenServer.call(pid, {:send_input, data})
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
    :ok = ProxmoxConsolePubSub.subscribe(session.id)

    state = %{
      session: session,
      owner: owner,
      required_gateway_node: nil,
      closed?: false
    }

    cols = Keyword.get(opts, :cols)
    rows = Keyword.get(opts, :rows)

    case send_frame(state, "open", open_frame_data(session, cols, rows), cols, rows, nil) do
      :ok -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_input, data}, _from, state) do
    {:reply, send_frame(state, "data", data, nil, nil, nil), state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    {:reply, send_frame(state, "resize", "", cols, rows, nil), state}
  end

  @impl true
  def handle_cast({:close, reason}, state) do
    _ = send_frame(state, "close", "", nil, nil, inspect(reason))
    {:stop, :normal, %{state | closed?: true}}
  end

  @impl true
  def handle_info({:proxmox_console_frame, %{frame_type: "data", data: data}}, state)
      when is_binary(data) do
    send(state.owner, {:proxmox_console_data, data})
    {:noreply, state}
  end

  def handle_info({:proxmox_console_frame, %{frame_type: frame_type, reason: reason}}, state)
      when frame_type in ["close", "error"] do
    send(state.owner, {:proxmox_console_closed, reason || frame_type})
    {:stop, :normal, %{state | closed?: true}}
  end

  def handle_info({:proxmox_console_frame, _frame}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(reason, %{closed?: false} = state) do
    _ = send_frame(state, "close", "", nil, nil, inspect(reason))
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp send_frame(state, frame_type, data, cols, rows, reason) do
    frame = %{
      session_id: state.session.id,
      frame_type: frame_type,
      data: data || "",
      cols: uint32(cols),
      rows: uint32(rows),
      reason: reason || "",
      timestamp: System.system_time(:second)
    }

    AgentCommandBus.send_console_frame(state.session.agent_id, frame,
      required_gateway_node: state.required_gateway_node
    )
  end

  defp uint32(value) when is_integer(value) and value > 0, do: min(value, 65_535)
  defp uint32(_value), do: 0

  defp positive_or(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_or(_value, fallback), do: fallback

  defp open_frame_data(session, cols, rows) do
    metadata = metadata_map(session)

    %{
      session_id: session.id,
      agent_id: session.agent_id,
      gateway_id: session.gateway_id,
      device_uid: session.device_uid,
      target_kind: format_atom(session.target_kind),
      console_mode: format_atom(session.console_mode),
      credential_rule_id: to_string(session.credential_rule_id),
      plugin_assignment_id: metadata_string(metadata, "plugin_assignment_id"),
      target:
        metadata
        |> Map.get("target", %{})
        |> enrich_target(metadata)
        |> normalize_target(),
      cols: positive_or(uint32(cols), terminal_int(session, "cols")),
      rows: positive_or(uint32(rows), terminal_int(session, "rows"))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", 0] end)
    |> Map.new()
    |> Jason.encode!()
  end

  defp terminal_int(session, key) do
    session
    |> metadata_map()
    |> Map.get("terminal", %{})
    |> case do
      terminal when is_map(terminal) -> uint32(Map.get(terminal, key))
      _terminal -> 0
    end
  end

  defp metadata_string(metadata, key) when is_map(metadata) do
    case Map.get(metadata, key) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp enrich_target(target, metadata) when is_map(target) and is_map(metadata) do
    remote_console =
      case Map.get(metadata, "remote_console") do
        value when is_map(value) -> value
        _value -> %{}
      end

    remote_metadata =
      case Map.get(remote_console, "metadata") do
        value when is_map(value) -> value
        _value -> %{}
      end

    target
    |> put_if_present("provider_ref", Map.get(remote_console, "target_ref"))
    |> put_if_present("target_ref", Map.get(remote_console, "target_ref"))
    |> put_if_present("target_type", Map.get(remote_console, "target_type"))
    |> put_if_present("target_kind", Map.get(remote_metadata, "target_kind"))
    |> put_if_present("console_mode", Map.get(remote_metadata, "console_mode"))
  end

  defp enrich_target(target, _metadata), do: target

  defp put_if_present(map, _key, value) when value in [nil, ""], do: map
  defp put_if_present(map, key, value), do: Map.put_new(map, key, value)

  defp normalize_target(target) when is_map(target) do
    target
    |> Enum.reject(fn {_key, value} -> value in [nil, "", 0] end)
    |> Map.new()
  end

  defp normalize_target(_target), do: %{}

  defp metadata_map(%{metadata: metadata}) when is_map(metadata), do: stringify_map(metadata)
  defp metadata_map(_session), do: %{}

  defp stringify_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} -> {to_string(key), stringify_nested(value)}
    end)
  end

  defp stringify_nested(value) when is_map(value), do: stringify_map(value)
  defp stringify_nested(value), do: value

  defp format_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp format_atom(value) when is_binary(value), do: value
  defp format_atom(_value), do: nil
end
