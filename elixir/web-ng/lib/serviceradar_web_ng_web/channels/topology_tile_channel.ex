defmodule ServiceRadarWebNGWeb.TopologyTileChannel do
  @moduledoc "Bounded revision hints for the geometry retained by one tile client."
  use Phoenix.Channel

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Topology.TileControl
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNGWeb.FeatureFlags

  @tick_ms 5_000
  @reconcile_timeout 30_000

  @impl true
  def join("topology:tiles", _params, socket) do
    with {:ok, socket} <- authorize(socket),
         {:ok, manifest} <- WorldCache.manifest() do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "topology:world")
      fence = TileControl.fence(manifest)
      Process.send_after(self(), :tile_tick, @tick_ms)

      state = %{
        fence: fence,
        watch: %{layout_version: fence.layout_version, generation: fence.generation, keys: [], tiles: %{}},
        watch_id: 0,
        reconciled: nil,
        task: nil,
        retry: nil
      }

      {:ok, fence, assign(socket, :tile_watch, state)}
    else
      {:error, reason} -> {:error, channel_error(reason)}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_in("tiles:watch", params, socket) do
    with {:ok, socket} <- authorize(socket),
         {:ok, watch} <- TileKey.watch(params),
         {:ok, manifest} <- WorldCache.manifest() do
      socket = advance_fence(socket, TileControl.fence(manifest))
      state = socket.assigns.tile_watch

      cond do
        Enum.any?(watch.keys, &(&1.z > manifest.zmax)) ->
          {:reply, {:error, %{reason: "invalid_tiles"}}, socket}

        watch.layout_version == state.fence.layout_version ->
          # Every watch carries the revisions actually retained by the client.
          # Sending an invalidation is never treated as a client acknowledgement.
          watch = Map.put(watch, :generation, state.fence.generation)
          state = %{state | watch: watch, watch_id: state.watch_id + 1}
          socket = socket |> assign(:tile_watch, cancel_task(state)) |> reconcile()
          {:reply, {:ok, Map.put(state.fence, :watch_id, state.watch_id)}, socket}

        true ->
          {:reply, {:error, Map.put(state.fence, :reason, "layout_changed")}, socket}
      end
    else
      {:error, reason} -> {:reply, {:error, channel_error(reason)}, socket}
    end
  end

  def handle_in(_event, _params, socket), do: {:reply, {:error, %{reason: "unsupported_event"}}, socket}

  @impl true
  def handle_info(:tile_tick, socket) do
    Process.send_after(self(), :tile_tick, @tick_ms)
    refresh(socket)
  end

  def handle_info({:topology_world_ready, _fence}, socket), do: refresh(socket)

  def handle_info(:tile_retry, socket) do
    state = %{socket.assigns.tile_watch | retry: nil}
    refresh(assign(socket, :tile_watch, state))
  end

  def handle_info({:tiles_reconciled, token, result}, socket) do
    state = socket.assigns.tile_watch

    case state.task do
      %{token: ^token, cancelled: false} = task ->
        socket = assign(socket, :tile_watch, release_task(state))

        with {:ok, socket} <- authorize(socket),
             {:ok, manifest} <- WorldCache.manifest() do
          socket = advance_fence(socket, TileControl.fence(manifest))
          state = socket.assigns.tile_watch

          if task.watch_id == state.watch_id and task.generation == state.fence.generation do
            deliver(result, socket)
          else
            {:noreply, reconcile(socket)}
          end
        else
          {:error, reason} -> failed(reason, socket)
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:tile_reconcile_timeout, token}, socket) do
    state = socket.assigns.tile_watch

    case state.task do
      %{token: ^token} -> {:noreply, assign(socket, :tile_watch, cancel_task(state))}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    state = socket.assigns.tile_watch

    case state.task do
      %{ref: ^ref, cancelled: cancelled} ->
        socket = assign(socket, :tile_watch, release_task(state))
        {:noreply, if(cancelled, do: reconcile(socket), else: retry(socket))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    state = socket.assigns[:tile_watch]
    if state, do: cancel_task(state)
    :ok
  end

  defp refresh(socket) do
    with {:ok, socket} <- authorize(socket),
         {:ok, manifest} <- WorldCache.manifest() do
      {:noreply, socket |> advance_fence(TileControl.fence(manifest)) |> reconcile()}
    else
      {:error, reason} -> failed(reason, socket)
    end
  end

  defp advance_fence(socket, fence) do
    state = socket.assigns.tile_watch

    if fence.generation > state.fence.generation do
      push(socket, "topology_generation", fence)
      assign(socket, :tile_watch, cancel_task(%{state | fence: fence}))
    else
      socket
    end
  end

  defp reconcile(socket) do
    state = socket.assigns.tile_watch
    identity = {state.watch_id, state.fence.generation}

    if state.task || state.retry || state.reconciled == identity do
      socket
    else
      owner = self()
      token = make_ref()

      case Task.Supervisor.start_child(ServiceRadarWebNG.Topology.TileWatchTasks, fn ->
             send(owner, {:tiles_reconciled, token, revisions(state.watch, state.fence)})
           end) do
        {:ok, pid} ->
          task = %{
            token: token,
            pid: pid,
            ref: Process.monitor(pid),
            cancelled: false,
            watch_id: state.watch_id,
            generation: state.fence.generation,
            timeout: Process.send_after(self(), {:tile_reconcile_timeout, token}, @reconcile_timeout)
          }

          assign(socket, :tile_watch, %{state | task: task})

        {:error, _reason} ->
          retry(socket)
      end
    end
  end

  defp revisions(watch, fence) do
    keys = if watch.layout_version == fence.layout_version, do: watch.keys, else: []

    Enum.reduce_while(keys, {:ok, Map.put(fence, :tiles, %{})}, fn key, {:ok, current} ->
      case WorldCache.fetch(key, :background) do
        {:ok, %{generation: generation, revision: revision}} when generation == fence.generation ->
          {:cont, {:ok, %{current | tiles: Map.put(current.tiles, TileKey.id(key), revision)}}}

        {:ok, _newer_tile} ->
          {:halt, {:error, :source_changed}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp deliver({:ok, current}, socket) do
    state = socket.assigns.tile_watch
    current = Map.put(current, :watch_id, state.watch_id)

    case TileControl.reconcile(state.watch, current) do
      {:ok, payload} ->
        push(socket, "topology_invalidated", payload)
        state = %{state | reconciled: {state.watch_id, state.fence.generation}}
        {:noreply, assign(socket, :tile_watch, state)}

      {:error, _reason} ->
        {:noreply, retry(socket)}
    end
  end

  defp deliver({:error, _reason}, socket), do: {:noreply, retry(socket)}

  defp cancel_task(%{task: nil} = state), do: state

  defp cancel_task(state) do
    Process.exit(state.task.pid, :kill)
    %{state | task: %{state.task | cancelled: true}}
  end

  defp release_task(state) do
    Process.cancel_timer(state.task.timeout)
    Process.demonitor(state.task.ref, [:flush])
    %{state | task: nil}
  end

  defp retry(socket) do
    state = socket.assigns.tile_watch

    if state.retry do
      socket
    else
      timer = Process.send_after(self(), :tile_retry, 1_000 + :rand.uniform(250))
      assign(socket, :tile_watch, %{state | retry: timer})
    end
  end

  defp failed(reason, socket) when reason in [:unauthorized, :forbidden, :god_view_disabled] do
    push(socket, "topology_error", channel_error(reason))
    {:stop, :normal, socket}
  end

  defp failed(_reason, socket), do: {:noreply, retry(socket)}

  defp authorize(socket) do
    with true <- FeatureFlags.god_view_enabled?(),
         %Scope{user: user} = scope when not is_nil(user) <- socket.assigns[:current_scope],
         {:ok, current_scope} <- RBAC.authorize_current(scope, ["analytics.view", "devices.view"]) do
      {:ok, assign(socket, :current_scope, current_scope)}
    else
      false -> {:error, :god_view_disabled}
      {:error, _reason} -> {:error, :forbidden}
      _ -> {:error, :unauthorized}
    end
  end

  defp channel_error(reason)
       when reason in [:unauthorized, :forbidden, :god_view_disabled, :invalid_tiles, :invalid_layout_version],
       do: %{reason: Atom.to_string(reason)}

  defp channel_error(_reason), do: %{reason: "world_unavailable"}
end
