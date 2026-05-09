defmodule ServiceRadar.Edge.RemoteAccessBroker do
  @moduledoc """
  Broker boundary for generic browser-to-agent remote-access byte streams.

  This uses the existing console frame control-stream path while the protobuf
  remains in compatibility mode. Open frames carry a `protocol` field so the Go
  agent can dispatch to protocol-specific adapters such as SSH.
  """

  use GenServer

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.RemoteAccessPubSub

  @callback start_link(map() | struct(), pid(), keyword()) :: GenServer.on_start()
  @callback send_input(pid(), binary()) :: :ok | {:error, term()}
  @callback resize(pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  @callback close(pid(), term()) :: :ok

  @default_protocol "ssh"
  @default_credential_mode "agent_local"
  @default_terminal_type "xterm-256color"
  @default_ssh_host_key_policy "skip_verify"

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
      required_gateway_node: Keyword.get(opts, :required_gateway_node),
      pubsub: pubsub(opts),
      closed?: false
    }

    cols = Keyword.get(opts, :cols)
    rows = Keyword.get(opts, :rows)

    case send_frame(state, "open", open_frame_data(session, opts), cols, rows, nil) do
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
  def handle_info({:remote_access_frame, %{frame_type: "data", data: data}}, state)
      when is_binary(data) do
    send(state.owner, {:remote_access_data, data})
    {:noreply, state}
  end

  def handle_info({:remote_access_frame, %{frame_type: frame_type, reason: reason}}, state)
      when frame_type in ["close", "error"] do
    send(state.owner, {:remote_access_closed, reason || frame_type})
    {:stop, :normal, %{state | closed?: true}}
  end

  def handle_info({:remote_access_frame, _frame}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, %{closed?: false} = state) do
    _ = send_frame(state, "close", "", nil, nil, inspect(reason))
    :ok
  end

  def terminate(_reason, _state), do: :ok

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

  defp open_frame_data(session, opts) do
    session_metadata = metadata(session)
    opts_metadata = Keyword.get(opts, :metadata, %{})
    target = target(session, opts_metadata, session_metadata)
    ssh = ssh_auth(session, opts_metadata, session_metadata)

    %{
      protocol: string_option(session, opts, "protocol", @default_protocol),
      session_id: session_id(session),
      agent_id: agent_id(session),
      gateway_id: value(session, "gateway_id"),
      target: target,
      ssh: ssh,
      credential_mode: string_option(session, opts, "credential_mode", @default_credential_mode),
      credential_ref: credential_ref(session, opts_metadata, session_metadata),
      terminal_type: string_option(session, opts, "terminal_type", @default_terminal_type),
      timeout_ms: int_option(session, opts, "timeout_ms"),
      ssh_host_key_policy:
        string_option(session, opts, "ssh_host_key_policy", @default_ssh_host_key_policy)
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
    |> Jason.encode!()
  end

  defp target(session, opts_metadata, session_metadata) do
    opts_metadata
    |> map_value("target")
    |> fallback(map_value(session_metadata, "target"))
    |> fallback(value(session, "target"))
    |> normalize_target()
  end

  defp normalize_target(target) when is_map(target) do
    target
    |> stringify_map()
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp normalize_target(_target), do: %{}

  defp ssh_auth(session, opts_metadata, session_metadata) do
    opts_metadata
    |> map_value("ssh")
    |> fallback(map_value(session_metadata, "ssh"))
    |> fallback(value(session, "ssh"))
    |> normalize_ssh_auth()
  end

  defp normalize_ssh_auth(auth) when is_map(auth) do
    auth
    |> stringify_map()
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp normalize_ssh_auth(_auth), do: %{}

  defp credential_ref(session, opts_metadata, session_metadata) do
    string_value(opts_metadata, "credential_ref") ||
      string_value(session_metadata, "credential_ref") ||
      string_value(session, "credential_ref") ||
      string_value(session, "credential_rule_id")
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

  defp blank?(value) when value in [nil, "", 0], do: true
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(_value), do: false

  defp stringify_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} -> {to_string(key), stringify_nested(value)}
    end)
  end

  defp stringify_nested(value) when is_map(value), do: stringify_map(value)
  defp stringify_nested(value), do: value

  defp uint32(value) when is_integer(value) and value > 0, do: min(value, 65_535)
  defp uint32(_value), do: 0

  defp pubsub(opts), do: Keyword.get(opts, :pubsub, RemoteAccessPubSub)
end
