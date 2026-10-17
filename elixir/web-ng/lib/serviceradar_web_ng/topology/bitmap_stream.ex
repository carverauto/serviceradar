defmodule ServiceRadarWebNG.Topology.BitmapStream do
  @moduledoc "One bounded membership response at a time on an existing tile channel."

  import Phoenix.Channel, only: [push: 3, reply: 2, socket_ref: 1]
  import Phoenix.Socket, only: [assign: 3]

  alias ServiceRadarWebNG.Topology.BitmapAuthority
  alias ServiceRadarWebNG.Topology.BitmapFrame
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapPrefixTags
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapView
  alias ServiceRadarWebNG.Topology.WorldCache

  @ack_timeout 15_000
  @task_timeout 1_500
  @transient_tick [
    :query_busy,
    :query_timeout,
    :query_unavailable,
    :index_unavailable,
    :index_not_ready,
    :membership_not_ready,
    :prefix_source_unavailable
  ]

  def init(socket), do: assign(socket, :bitmap_stream, empty())

  def watch(params, socket) do
    with true <- BitmapQueries.enabled?(), {:ok, _watch} <- BitmapView.validate(params) do
      socket = reset(socket)
      state = socket.assigns.bitmap_stream

      if state.task do
        {:reply, {:error, error(:query_busy)}, socket}
      else
        state = %{state | request: params, reply: socket_ref(socket)}
        {:noreply, launch(assign(socket, :bitmap_stream, state))}
      end
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
    assign(socket, :bitmap_stream, %{state | metadata: nil, awaiting: nil})
  end

  def reset(socket, params \\ %{})

  def reset(socket, params) when is_map(params) do
    if reset_applies?(socket.assigns.bitmap_stream.metadata, params) do
      apply_reset(socket)
    else
      socket
    end
  end

  defp reset_applies?(metadata, %{"view_digest" => digest}) when is_binary(digest) do
    match?(%{view_digest: ^digest}, metadata)
  end

  defp reset_applies?(_metadata, _params), do: true

  defp apply_reset(socket) do
    state = cancel(socket.assigns.bitmap_stream)

    if state.metadata do
      case BitmapFrame.encode(Map.put(state.metadata, :kind, :reset)) do
        {:ok, frame} -> push(socket, "membership:frame", {:binary, frame})
        _ -> :ok
      end
    end

    assign(socket, :bitmap_stream, %{state | metadata: nil, awaiting: nil})
  end

  def tick(socket) do
    state = socket.assigns.bitmap_stream

    cond do
      !BitmapQueries.enabled?() -> reset(socket)
      state.awaiting && now() - state.awaiting >= @ack_timeout -> reset(socket)
      state.awaiting || state.task || is_nil(state.request) -> socket
      unchanged?(socket, state) -> socket
      true -> launch(socket)
    end
  end

  def completed(token, result, socket) do
    state = socket.assigns.bitmap_stream

    case state.task do
      %{token: ^token} ->
        state = release(state)

        with true <- not is_nil(state.request),
             {:ok, result} <- BitmapQueries.normalize(result),
             :ok <- BitmapView.confirm_delivery(socket.assigns.current_scope, result) do
          deliver(result, state, socket)
        else
          false -> assign(socket, :bitmap_stream, state)
          {:error, reason} -> failed(state, reason, socket)
        end

      _ ->
        socket
    end
  end

  defp deliver(result, state, socket) do
    if state.metadata && stable_binding(state.metadata) != stable_binding(result.metadata) do
      reset(assign(socket, :bitmap_stream, state))
    else
      reply_to = state.reply
      state = %{
        state
        | reply: nil,
          metadata: result.metadata,
          awaiting: now(),
          identity: delivered_identity(socket, result.metadata)
      }
      socket = assign(socket, :bitmap_stream, state)
      if reply_to, do: reply(reply_to, {:ok, result.binding})
      push(socket, "membership:frame", {:binary, result.frame})
      socket
    end
  end

  def timeout(token, socket) do
    case socket.assigns.bitmap_stream.task do
      %{token: ^token} -> failed(socket.assigns.bitmap_stream, :query_timeout, socket)
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
    if state = socket.assigns[:bitmap_stream] do
      if state.task, do: Process.exit(state.task.pid, :kill)
      release(state)
    end

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
    state = %{state | reply: nil}

    if keep_frame?(socket, state, reason) do
      assign(socket, :bitmap_stream, state)
    else
      reset(assign(socket, :bitmap_stream, state))
    end
  end

  defp empty, do: %{sequence: 0, request: nil, reply: nil, task: nil, metadata: nil, awaiting: nil, identity: :stale}

  defp unchanged?(socket, %{identity: {:ok, identity}, metadata: metadata}) when not is_nil(metadata) do
    not named_prefix_query?(metadata) and fresh_identity(socket, metadata) == {:ok, identity}
  end

  defp unchanged?(_socket, _state), do: false

  defp keep_frame?(socket, %{metadata: metadata, identity: {:ok, stored}}, reason)
       when not is_nil(metadata) and reason in @transient_tick do
    case fresh_identity(socket, metadata) do
      {:ok, fresh} -> Map.delete(fresh, :index_revision) == Map.delete(stored, :index_revision)
      _ -> false
    end
  end

  defp keep_frame?(_socket, _state, _reason), do: false

  defp delivered_identity(socket, metadata) do
    case fresh_identity(socket, metadata) do
      {:ok, identity} -> {:ok, %{identity | index_revision: built_revision(metadata)}}
      other -> other
    end
  end

  defp built_revision(%{index_revision: revision}) when is_integer(revision), do: revision

  defp built_revision(%{index_revision: revision}) when is_binary(revision) do
    case Integer.parse(revision) do
      {revision, ""} -> revision
      _ -> :unparsed
    end
  end

  defp built_revision(_metadata), do: :unparsed

  defp named_prefix_query?(%{prefix_sources: sources}) when is_map(sources), do: map_size(sources) > 0
  defp named_prefix_query?(_metadata), do: false

  defp fresh_identity(socket, metadata) do
    with {:ok, %{ordinals: %{info: info}, manifest: manifest}} <- WorldCache.world(),
         {:ok, snapshot} <- BitmapIndex.snapshot(),
         {:ok, authority} <- BitmapAuthority.current(socket.assigns.current_scope),
         :ok <- BitmapPrefixTags.current(metadata.prefix_sources || %{}) do
      {:ok,
       %{
         layout_version: manifest.layout_version,
         generation: manifest.generation,
         world_epoch: info.dictionary_epoch,
         assignment: info.assignment,
         dictionary_epoch: snapshot.dictionary_epoch,
         index_epoch: snapshot.index_epoch,
         index_revision: snapshot.progress.index_revision,
         authority: authority
       }}
    else
      _ -> :stale
    end
  end

  defp cancel(state, reason \\ :membership_replaced) do
    if state.reply, do: reply(state.reply, {:error, error(reason)})
    # Keep the slot until the bounded query exits. Killing only its caller would
    # leave the inner query running and let repeated watches exhaust the pool.
    %{state | reply: nil, request: nil}
  end

  defp release(%{task: nil} = state), do: state

  defp release(state) do
    Process.cancel_timer(state.task.timer)
    Process.demonitor(state.task.ref, [:flush])
    %{state | task: nil}
  end

  defp stable_binding(metadata),
    do: Map.take(metadata, [:dictionary_epoch, :query_digest, :authority_fingerprint, :view_digest])

  defp error(reason), do: %{reason: BitmapQueries.public_reason(reason)}
  defp now, do: System.monotonic_time(:millisecond)
end
