defmodule ServiceRadarWebNG.Topology.BitmapStream do
  @moduledoc "One bounded membership response at a time on an existing tile channel."

  import Phoenix.Channel, only: [push: 3, reply: 2, socket_ref: 1]
  import Phoenix.Socket, only: [assign: 3]

  alias ServiceRadarWebNG.Topology.BitmapFrame
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapView
  alias ServiceRadarWebNG.Topology.WorldCache

  @ack_timeout 15_000
  @task_timeout 1_500

  def init(socket), do: assign(socket, :bitmap_stream, empty())

  def watch(params, socket) do
    with true <- BitmapQueries.enabled?(), {:ok, _watch} <- BitmapView.validate(params) do
      state = cancel(socket.assigns.bitmap_stream)
      state = %{empty() | sequence: state.sequence, request: params, reply: socket_ref(socket)}
      {:noreply, launch(assign(socket, :bitmap_stream, state))}
    else
      false -> {:reply, {:error, %{reason: "bitmap_disabled"}}, socket}
      {:error, reason} -> {:reply, {:error, error(reason)}, socket}
    end
  end

  def ack(%{"sequence" => sequence, "view_digest" => digest}, socket) do
    state = socket.assigns.bitmap_stream

    if state.awaiting && sequence == Integer.to_string(state.sequence) && digest == state.metadata.view_digest do
      {:reply, :ok, assign(socket, :bitmap_stream, %{state | awaiting: nil})}
    else
      {:reply, {:error, %{reason: "obsolete_membership_ack"}}, socket}
    end
  end

  def ack(_params, socket), do: {:reply, {:error, %{reason: "invalid_membership_ack"}}, socket}

  def unwatch(socket) do
    state = cancel(socket.assigns.bitmap_stream)
    assign(socket, :bitmap_stream, %{empty() | sequence: state.sequence})
  end

  def reset(socket) do
    state = cancel(socket.assigns.bitmap_stream)

    if state.metadata do
      case BitmapFrame.encode(Map.put(state.metadata, :kind, :reset)) do
        {:ok, frame} -> push(socket, "membership:frame", {:binary, frame})
        _ -> :ok
      end
    end

    assign(socket, :bitmap_stream, %{empty() | sequence: state.sequence})
  end

  def tick(socket) do
    state = socket.assigns.bitmap_stream

    cond do
      !BitmapQueries.enabled?() -> reset(socket)
      state.awaiting && now() - state.awaiting >= @ack_timeout -> reset(socket)
      state.awaiting || state.task || is_nil(state.request) -> socket
      true -> launch(socket)
    end
  end

  def completed(token, result, socket) do
    state = socket.assigns.bitmap_stream

    case state.task do
      %{token: ^token} ->
        state = release(state)

        with {:ok, result} <- BitmapQueries.normalize(result), :ok <- current(result, socket) do
          deliver(result, state, socket)
        else
          {:error, reason} -> failed(state, reason, socket)
        end

      _ ->
        socket
    end
  end

  defp current(result, socket) do
    with true <- BitmapQueries.enabled?(),
         :ok <- BitmapQueries.confirm_delivery(socket.assigns.current_scope, result.authority, result.deadline),
         {:ok, manifest} <- WorldCache.manifest(),
         true <- manifest.generation == result.generation,
         {:ok, snapshot} <- BitmapIndex.snapshot(),
         true <- Ecto.UUID.load!(snapshot.dictionary_epoch) == result.metadata.dictionary_epoch,
         true <- Ecto.UUID.load!(snapshot.index_epoch) == result.metadata.index_epoch,
         {:ok, _budget} <- BitmapQueries.remaining(result.deadline) do
      :ok
    else
      false -> {:error, :source_changed}
      error -> error
    end
  end

  defp deliver(result, state, socket) do
    if state.metadata && stable_binding(state.metadata) != stable_binding(result.metadata) do
      reset(assign(socket, :bitmap_stream, state))
    else
      if state.reply, do: reply(state.reply, {:ok, result.binding})
      push(socket, "membership:frame", {:binary, result.frame})
      state = %{state | reply: nil, metadata: result.metadata, awaiting: now()}
      assign(socket, :bitmap_stream, state)
    end
  end

  def timeout(token, socket) do
    case socket.assigns.bitmap_stream.task do
      %{token: ^token} -> failed(cancel(socket.assigns.bitmap_stream, :query_timeout), :query_timeout, socket)
      _ -> socket
    end
  end

  def down(ref, socket) do
    case socket.assigns.bitmap_stream.task do
      %{ref: ^ref} -> failed(release(socket.assigns.bitmap_stream), :query_unavailable, socket)
      _ -> socket
    end
  end

  def terminate(socket) do
    if socket.assigns[:bitmap_stream], do: cancel(socket.assigns.bitmap_stream)
    :ok
  end

  defp launch(socket) do
    state = socket.assigns.bitmap_stream
    owner = self()
    token = make_ref()
    scope = socket.assigns.current_scope
    sequence = state.sequence + 1
    request = state.request

    case Task.Supervisor.start_child(ServiceRadarWebNG.Topology.TileWatchTasks, fn ->
           send(owner, {:membership_built, token, BitmapView.build(scope, request, sequence)})
         end) do
      {:ok, pid} ->
        task = %{
          pid: pid,
          ref: Process.monitor(pid),
          token: token,
          timer: Process.send_after(owner, {:membership_timeout, token}, @task_timeout)
        }

        assign(socket, :bitmap_stream, %{state | task: task, sequence: sequence})

      {:error, _reason} ->
        failed(state, :query_busy, socket)
    end
  end

  defp failed(state, reason, socket) do
    if state.reply, do: reply(state.reply, {:error, error(reason)})
    reset(assign(socket, :bitmap_stream, %{state | reply: nil}))
  end

  defp empty, do: %{sequence: 0, request: nil, reply: nil, task: nil, metadata: nil, awaiting: nil}

  defp cancel(state, reason \\ :membership_replaced) do
    if state.reply, do: reply(state.reply, {:error, error(reason)})
    if state.task, do: Process.exit(state.task.pid, :kill)
    %{release(state) | reply: nil}
  end

  defp release(%{task: nil} = state), do: state

  defp release(state) do
    Process.cancel_timer(state.task.timer)
    Process.demonitor(state.task.ref, [:flush])
    %{state | task: nil}
  end

  defp stable_binding(metadata),
    do: Map.take(metadata, [:dictionary_epoch, :query_digest, :authority_fingerprint, :view_digest])

  defp error(reason) when is_atom(reason) or is_binary(reason), do: %{reason: to_string(reason)}
  defp error(_reason), do: %{reason: "query_unavailable"}
  defp now, do: System.monotonic_time(:millisecond)
end
