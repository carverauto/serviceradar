defmodule ServiceRadarAgentGateway.AgentRegistryProxy do
  @moduledoc """
  Owns AgentRegistry entries for Go agents connected through the gateway.

  Horde registry entries are tied to the registering process PID. gRPC request
  handlers are short-lived, so this proxy registers agents on a stable PID and
  updates their metadata/heartbeats.

  Because the entries outlive the requests that create them, the proxy also ends
  them:

    * It monitors every control-stream session that reports to it, and owns the
      entry's `status`: `:connected` exactly while the agent has a live control
      session on this gateway, `:disconnected` otherwise. Commands reach an agent
      only over its control stream, so a status push or unary hello updates
      liveness and metadata but never the status; an agent whose stream is gone
      is not offered as connected however often it pushes. A new session marks
      the agent connected once it is monitored, so the old session's exit during
      a reconnect cannot leave a live agent marked disconnected.
    * Agents not heard from (no touch, no session report) for the stale window
      and without a live session are unregistered, and their negotiated delivery
      capabilities are dropped. The window is longer than the agent's slowest
      heartbeat, so this only removes agents that have gone away.

  Negotiated capabilities deliberately survive the end of a control session: an
  agent keeps pushing retained results over unary RPCs after its stream drops,
  and those must still be acknowledged under the capabilities it negotiated.
  """

  use GenServer

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.ProcessRegistry

  require Logger

  # Agents send a status heartbeat at least every five minutes.
  @default_stale_after_ms to_timeout(minute: 15)
  @default_sweep_interval_ms to_timeout(minute: 1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec touch_agent(String.t(), map()) :: :ok | {:error, term()}
  def touch_agent(agent_id, metadata) do
    GenServer.call(__MODULE__, {:touch_agent, agent_id, metadata})
  end

  @doc "Returns capabilities negotiated for one authenticated edge principal."
  @spec delivery_capabilities(String.t(), String.t()) :: [String.t()]
  def delivery_capabilities(partition_id, agent_id) do
    case live_control_capabilities(partition_id, agent_id) do
      {:ok, capabilities} ->
        capabilities

      :not_found ->
        GenServer.call(__MODULE__, {:delivery_capabilities, partition_id, agent_id})
    end
  end

  @doc false
  @spec sync_delivery_capabilities(String.t(), String.t(), [String.t()]) ::
          :ok | {:error, :proxy_unavailable}
  #
  # A call that times out is not lost: the request stays in the proxy's mailbox
  # and is still handled, monitoring the session. With no proxy running at all,
  # the next proxy adopts the session from its registry entry in init/1.
  def sync_delivery_capabilities(partition_id, agent_id, capabilities)
      when is_binary(partition_id) and is_binary(agent_id) and is_list(capabilities) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:sync_delivery_capabilities, partition_id, agent_id, capabilities}, 1_000)

      nil ->
        Logger.warning("Agent registry proxy unavailable for control session report", agent_id: agent_id)
        {:error, :proxy_unavailable}
    end
  catch
    :exit, reason ->
      Logger.warning("Agent registry proxy did not answer a control session report: #{inspect(reason)}",
        agent_id: agent_id
      )

      {:error, :proxy_unavailable}
  end

  @doc """
  Unregisters agents that have been silent for the stale window and have no live
  control session. Runs periodically; callable directly to force a pass.
  """
  @spec sweep_stale_agents() :: :ok
  def sweep_stale_agents do
    GenServer.call(__MODULE__, :sweep_stale_agents)
  end

  @impl true
  def init(opts) do
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    schedule_sweep(sweep_interval_ms)

    state = %{
      capabilities: %{},
      # agent_id => %{session_pid => monitor_ref}
      sessions: %{},
      # monitor_ref => {agent_id, session_pid}
      session_refs: %{},
      # agent_id => monotonic ms of the last touch or session report
      last_seen: %{},
      sweep_interval_ms: sweep_interval_ms
    }

    {:ok, Enum.reduce(live_control_sessions(), state, &adopt_live_session/2)}
  end

  @impl true
  def handle_call({:touch_agent, agent_id, metadata}, _from, state) do
    next_state =
      state
      |> put_delivery_capabilities(agent_id, metadata)
      |> mark_seen(agent_id)

    metadata = Map.put(metadata, :status, control_status(state, agent_id))

    case ProcessRegistry.update_value({:agent, agent_id, node()}, fn existing ->
           existing
           |> Map.merge(metadata)
           |> Map.put(:last_heartbeat, DateTime.utc_now())
         end) do
      {_new_metadata, _old_metadata} ->
        {:reply, :ok, next_state}

      :error ->
        case AgentRegistry.register_agent(agent_id, metadata) do
          {:ok, _pid} ->
            {:reply, :ok, next_state}

          {:error, {:already_registered, _pid}} ->
            {:reply, :ok, next_state}
        end
    end
  end

  @impl true
  def handle_call({:delivery_capabilities, partition_id, agent_id}, _from, state) do
    capabilities = Map.get(state.capabilities, {partition_id, agent_id}, [])

    {:reply, capabilities, state}
  end

  def handle_call({:sync_delivery_capabilities, partition_id, agent_id, capabilities}, {session, _tag}, state) do
    state =
      state
      |> put_in([:capabilities, {partition_id, agent_id}], capabilities)
      |> mark_seen(agent_id)
      |> track_session(agent_id, session)

    {:reply, :ok, state}
  end

  def handle_call(:sweep_stale_agents, _from, state) do
    {:reply, :ok, sweep(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.session_refs, ref) do
      {{agent_id, session}, session_refs} ->
        state = %{state | session_refs: session_refs}
        {:noreply, session_ended(state, agent_id, session)}

      {nil, _session_refs} ->
        {:noreply, state}
    end
  end

  def handle_info(:sweep_stale_agents, state) do
    state = sweep(state)
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp put_delivery_capabilities(state, agent_id, %{partition_id: partition_id, capabilities: capabilities})
       when is_binary(partition_id) and is_list(capabilities) do
    put_in(state, [:capabilities, {partition_id, agent_id}], capabilities)
  end

  defp put_delivery_capabilities(state, _agent_id, _metadata), do: state

  defp mark_seen(state, agent_id) do
    put_in(state, [:last_seen, agent_id], System.monotonic_time(:millisecond))
  end

  # Sessions report on registration, on every hello and from terminate/2. The
  # one dying in terminate/2 is monitored too, and its :DOWN follows promptly.
  defp track_session(state, agent_id, session) when node(session) == node() do
    sessions = Map.get(state.sessions, agent_id, %{})

    if Map.has_key?(sessions, session) do
      state
    else
      ref = Process.monitor(session)
      mark_connected(agent_id)

      %{
        state
        | sessions: Map.put(state.sessions, agent_id, Map.put(sessions, session, ref)),
          session_refs: Map.put(state.session_refs, ref, {agent_id, session})
      }
    end
  end

  defp track_session(state, _agent_id, _session), do: state

  defp session_ended(state, agent_id, session) do
    remaining = state.sessions |> Map.get(agent_id, %{}) |> Map.delete(session)

    if map_size(remaining) == 0 do
      mark_disconnected(agent_id)
      %{state | sessions: Map.delete(state.sessions, agent_id)}
    else
      %{state | sessions: Map.put(state.sessions, agent_id, remaining)}
    end
  end

  defp mark_disconnected(agent_id) do
    case ProcessRegistry.update_value({:agent, agent_id, node()}, &Map.put(&1, :status, :disconnected)) do
      {_new_metadata, %{status: :connected}} -> broadcast({:agent_disconnected, agent_id})
      _other -> :ok
    end
  end

  defp control_status(state, agent_id) do
    if Map.has_key?(state.sessions, agent_id), do: :connected, else: :disconnected
  end

  # The entry may not exist yet (a proxy restart adopts sessions before their
  # agents touch it); the agent's next touch then registers it as connected.
  defp mark_connected(agent_id) do
    case ProcessRegistry.update_value({:agent, agent_id, node()}, &Map.put(&1, :status, :connected)) do
      {new_metadata, %{status: old_status}} when old_status != :connected ->
        broadcast({:agent_registered, new_metadata})

      _other ->
        :ok
    end
  end

  defp sweep(state) do
    now = System.monotonic_time(:millisecond)
    stale_after_ms = stale_after_ms()

    stale =
      for {agent_id, seen_at} <- state.last_seen,
          now - seen_at >= stale_after_ms,
          not Map.has_key?(state.sessions, agent_id),
          do: agent_id

    Enum.reduce(stale, state, &forget_agent/2)
  end

  defp forget_agent(agent_id, state) do
    case ProcessRegistry.lookup({:agent, agent_id, node()}) do
      [{_pid, %{status: :connected}} | _] ->
        ProcessRegistry.unregister_agent(agent_id)
        broadcast({:agent_disconnected, agent_id})

      _other ->
        ProcessRegistry.unregister_agent(agent_id)
    end

    Logger.debug("Unregistered stale agent #{agent_id}")

    %{
      state
      | last_seen: Map.delete(state.last_seen, agent_id),
        capabilities: Map.reject(state.capabilities, fn {{_partition_id, id}, _caps} -> id == agent_id end)
    }
  end

  defp stale_after_ms do
    Application.get_env(:serviceradar_agent_gateway, :agent_registry_stale_after_ms, @default_stale_after_ms)
  end

  defp schedule_sweep(interval_ms), do: Process.send_after(self(), :sweep_stale_agents, interval_ms)

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(ServiceRadar.PubSub, "agent:registrations", message)
  rescue
    ArgumentError -> :ok
  end

  defp live_control_capabilities(partition_id, agent_id) when is_binary(partition_id) and is_binary(agent_id) do
    key = {:agent_control, partition_id, agent_id, node()}

    if Process.whereis(ProcessRegistry.registry_name()) do
      key
      |> ProcessRegistry.lookup()
      |> Enum.find_value(:not_found, &live_capabilities/1)
    else
      :not_found
    end
  catch
    :exit, _reason -> :not_found
  end

  defp live_control_capabilities(_partition_id, _agent_id), do: :not_found

  defp live_capabilities({pid, %{capabilities: capabilities}}) when is_pid(pid) and is_list(capabilities) do
    if node(pid) == node() and Process.alive?(pid), do: {:ok, capabilities}
  end

  defp live_capabilities(_entry), do: nil

  # After a restart, the proxy re-learns the sessions that are still running from
  # their own registry entries, which die with them.
  defp live_control_sessions do
    if Process.whereis(ProcessRegistry.registry_name()) do
      ProcessRegistry.select_by_type(:agent_control)
    else
      []
    end
  catch
    :exit, _reason -> []
  end

  defp adopt_live_session(
         {{:agent_control, partition_id, agent_id, registry_node}, pid, %{capabilities: capabilities}},
         state
       )
       when is_binary(partition_id) and is_binary(agent_id) and is_pid(pid) and is_list(capabilities) do
    if registry_node == node() and node(pid) == node() and Process.alive?(pid) do
      state
      |> put_in([:capabilities, {partition_id, agent_id}], capabilities)
      |> mark_seen(agent_id)
      |> track_session(agent_id, pid)
    else
      state
    end
  end

  defp adopt_live_session(_entry, state), do: state
end
