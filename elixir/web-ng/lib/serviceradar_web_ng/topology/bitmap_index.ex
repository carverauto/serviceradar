defmodule ServiceRadarWebNG.Topology.BitmapIndex do
  @moduledoc """
  Owns one local device index, repaired by bounded current-state scans.

  PubSub identities are hints, never a commit watermark. A capped UID inbox
  resolves hints into the native Roaring dirty queue. One supervised worker
  alternates hint resolution, dirty reads and full ordinal keyset reconciliation.
  The owner retains one drained batch of at most 500 ordinals until publication
  succeeds, including while native contention prevents a queue write.
  Ordinary reconciliation retains the ready snapshot; failures report stale
  progress while retrying. No database work runs in the owner process.
  """
  use GenServer

  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadarWebNG.Topology.BitmapPrefixTags
  alias ServiceRadarWebNG.Topology.BitmapPublisher
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapSource
  alias ServiceRadarWebNG.Topology.Native

  require Logger

  @batch_size 500
  @hint_limit 5_000
  @hint_bytes 524_288
  @task_timeout 10_000
  @step_interval 25
  @scan_interval 30_000
  @shutdown_cleanup_timeout 4_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot, 1_000)
  catch
    :exit, _ -> {:error, :index_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    pubsub = Keyword.fetch!(opts, :pubsub)
    Phoenix.PubSub.subscribe(pubsub, DevicePubSub.invalidation_topic())
    Phoenix.PubSub.subscribe(pubsub, Loader.pubsub_topic())
    send(self(), :step)
    Process.send_after(self(), :feature_check, 1_000)

    {:ok,
     %{
       pubsub: pubsub,
       tasks: Keyword.fetch!(opts, :task_supervisor),
       current: nil,
       mode: :initialize,
       cursor: nil,
       active: nil,
       timer: nil,
       hints: MapSet.new(),
       hint_bytes: 0,
       dirty: [],
       rescan: true,
       scan_due: 0,
       catalog_due: 0,
       catalog_sources: [],
       catalog_turn: 0,
       scan_generation: 0,
       scan_started_at: nil,
       seeded_at: nil,
       last_reconciled_at: nil,
       source_error: false,
       retry_at: nil,
       sequence: 0,
       turn: 0
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    cond do
      not BitmapQueries.enabled?() ->
        {:reply, {:error, :bitmap_disabled}, disable(state)}

      state.mode != :ready ->
        {:reply, {:error, :index_not_ready}, state}

      true ->
        reply =
          with {:ok, status} <- Native.bitmap_index_status(state.current.device) do
            if status.ready do
              progress = %{
                seeded_at: state.seeded_at,
                last_reconciled_at: state.last_reconciled_at,
                pending_dirty: status.pending.pending_count + MapSet.size(state.hints) + length(state.dirty),
                source_error: state.source_error,
                reconciling: not is_nil(state.cursor) or state.rescan or status.pending.rescan_needed,
                ip_available: status.ip_available,
                ip_unavailable_reason: status.ip_unavailable_reason,
                index_revision: status.revision
              }

              {:ok, Map.put(state.current, :progress, progress)}
            else
              {:error, :index_not_ready}
            end
          end

        {:reply, reply, state}
    end
  end

  @impl true
  def handle_info(:step, state), do: {:noreply, step(%{state | timer: nil, retry_at: nil})}

  def handle_info(:feature_check, state) do
    Process.send_after(self(), :feature_check, 1_000)
    {:noreply, if(BitmapQueries.enabled?(), do: wake(state), else: disable(state))}
  end

  def handle_info({:devices_invalidated, ids}, state) do
    {:noreply, if(BitmapQueries.enabled?(), do: state |> remember(ids) |> wake(), else: state)}
  end

  def handle_info(:devices_rescan, state), do: {:noreply, wake(%{state | rescan: true})}

  def handle_info({:prefix_tags_snapshot_changed, _metadata}, state), do: {:noreply, wake(%{state | catalog_due: 0})}

  def handle_info({:bitmap_finished, token, result}, %{active: %{token: token, timed_out: false}} = state) do
    work = state.active.work
    state = release(state)

    case result do
      {:ok, result} ->
        {:noreply, state |> accept(work, result) |> Map.put(:retry_at, nil) |> schedule(@step_interval)}

      {:error, :dictionary_changed} ->
        {:noreply, state |> disable() |> schedule(0)}

      {:error, reason} ->
        {:noreply, retry(state, work, reason)}
    end
  end

  def handle_info({:bitmap_timeout, token}, %{active: %{token: token, timed_out: false}} = state) do
    Process.exit(state.active.pid, :kill)
    {:noreply, %{state | active: %{state.active | timed_out: true}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{ref: ref}} = state) do
    work = state.active.work
    {:noreply, state |> release() |> retry(work)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: drain(state, now() + @shutdown_cleanup_timeout)

  defp step(state) do
    cond do
      not BitmapQueries.enabled?() -> disable(state)
      not is_nil(state.active) -> state
      state.mode == :closing -> retry_close(state)
      state.mode == :initialize -> launch(state, :initialize)
      state.mode == :backfill -> launch(state, {:backfill, state.cursor})
      true -> next_read(state)
    end
  end

  defp next_read(state) do
    case Native.bitmap_index_status(state.current.device) do
      {:ok, status} ->
        state = start_scan(state, status.pending)
        choose_read(state, status.pending, 0)

      {:error, reason} ->
        retry(state, :status, reason)
    end
  end

  defp start_scan(%{cursor: nil} = state, status) do
    if state.mode == :seed or state.rescan or status.rescan_needed or state.scan_due <= now() do
      %{
        state
        | cursor: 0,
          scan_generation: status.rescan_generation,
          scan_started_at: DateTime.utc_now(),
          rescan: false
      }
    else
      state
    end
  end

  defp start_scan(state, _status), do: state

  defp choose_read(state, _status, 4), do: schedule(state, 1_000)

  defp choose_read(state, status, checked) do
    turn = rem(state.turn, 4)
    next = %{state | turn: turn + 1}

    cond do
      turn == 0 and MapSet.size(state.hints) > 0 ->
        ids = Enum.take(state.hints, @batch_size)
        hints = MapSet.difference(state.hints, MapSet.new(ids))

        launch(
          %{next | hints: hints, hint_bytes: state.hint_bytes - Enum.sum(Enum.map(ids, &byte_size/1))},
          {:hints, ids}
        )

      turn == 1 and (state.dirty != [] or status.pending_count > 0) ->
        read_dirty(next, status, checked)

      turn == 2 and not is_nil(state.cursor) ->
        launch(next, {:scan, state.cursor, state.mode, state.scan_generation})

      turn == 3 and state.catalog_due <= now() ->
        catalog_work(next)

      true ->
        choose_read(next, status, checked + 1)
    end
  end

  defp read_dirty(%{dirty: []} = state, status, checked) do
    case Native.bitmap_index_take_dirty(state.current.device, @batch_size) do
      {:ok, {[], _status}} -> choose_read(state, status, checked + 1)
      {:ok, {ordinals, _status}} -> read_dirty(%{state | dirty: ordinals}, status, checked)
      {:error, reason} -> retry(state, :dirty, reason)
    end
  end

  defp read_dirty(state, _status, _checked) do
    # Keep the one bounded batch until its worker succeeds. Requeueing it into
    # the native index can fail on the same lock that prevented publication.
    launch(state, {:dirty, state.mode == :ready, state.dirty})
  end

  defp catalog_work(state) do
    case BitmapPrefixTags.sources() do
      {:ok, sources} ->
        remaining = BitmapPrefixTags.release(state.catalog_sources -- sources)

        if remaining == [] do
          # Record bounded names before starting native work so cancellation and
          # feature disable can release a catalog prepared by the worker.
          {before, after_turn} = Enum.split(sources, rem(state.catalog_turn, max(length(sources), 1)))

          launch(
            %{state | catalog_sources: sources, catalog_turn: state.catalog_turn + 1},
            {:catalog, after_turn ++ before}
          )
        else
          schedule(%{state | catalog_due: now() + 1_000}, @step_interval)
        end

      {:error, _} ->
        schedule(%{state | catalog_due: now() + @scan_interval}, @step_interval)
    end
  end

  defp launch(state, work) do
    token = make_ref()
    owner = self()
    sequence = state.sequence + 1
    current = state.current

    case Task.Supervisor.start_child(state.tasks, fn ->
           result = perform(work, current, sequence)
           send(owner, {:bitmap_finished, token, result})
         end) do
      {:ok, pid} ->
        active = %{
          pid: pid,
          ref: Process.monitor(pid),
          token: token,
          work: work,
          timed_out: false,
          timeout: Process.send_after(self(), {:bitmap_timeout, token}, @task_timeout)
        }

        %{state | active: active, sequence: sequence}

      {:error, _} ->
        retry(state, work)
    end
  end

  defp perform(:initialize, _current, _sequence) do
    with {:ok, info} <- BitmapSource.initialize(),
         epoch = :crypto.strong_rand_bytes(16),
         {:ok, index} <- Native.bitmap_index_new(info.dictionary_epoch, epoch, :device, info.supported_facets) do
      {:ok, Map.merge(info, %{device: index, index_epoch: epoch})}
    end
  end

  defp perform({:backfill, cursor}, _current, _sequence), do: BitmapSource.backfill(cursor)

  defp perform({:catalog, sources}, _current, _sequence), do: BitmapPrefixTags.prepare(sources, now() + 1_000)

  defp perform({:hints, ids}, current, _sequence) do
    with {:ok, ordinals} <- BitmapSource.resolve_ids(ids),
         {:ok, _} <- Native.bitmap_index_mark_dirty(current.device, ordinals, false),
         do: {:ok, nil}
  end

  defp perform({:scan, cursor, mode, generation}, current, sequence) do
    with :ok <- source_identity(current, cursor),
         {:ok, page} <-
           BitmapPublisher.publish(
             current,
             fn -> BitmapSource.page(cursor, current.supported_facets) end,
             fn page -> mode == :ready or page.done? end,
             sequence
           ) do
      acknowledge_reconcile(page, current.device, generation)
    end
  end

  defp acknowledge_reconcile(%{done?: true} = page, device, generation) do
    case Native.bitmap_index_acknowledge_reconcile(device, generation) do
      {:ok, _status} -> {:ok, page}
      {:error, reason} when reason in ["stale_reconcile", :stale_reconcile] -> {:ok, page}
      {:error, reason} -> {:error, reason}
    end
  end

  defp acknowledge_reconcile(page, _device, _generation), do: {:ok, page}

  defp perform({:dirty, ready, ordinals}, current, sequence) do
    with {:ok, _} <-
           BitmapPublisher.publish(
             current,
             fn ->
               with {:ok, rows} <- BitmapSource.fetch(ordinals, current.supported_facets),
                    do: {:ok, %{rows: rows}}
             end,
             fn _ -> ready end,
             sequence
           ),
         do: {:ok, nil}
  end

  defp source_identity(current, 0) do
    with {:ok, source} <- BitmapSource.initialize() do
      if source.dictionary_epoch == current.dictionary_epoch and source.supported_facets == current.supported_facets,
        do: :ok,
        else: {:error, :dictionary_changed}
    end
  end

  defp source_identity(_current, _cursor), do: :ok

  defp accept(state, :initialize, current),
    do: %{state | current: current, mode: :backfill, cursor: nil, source_error: false}

  defp accept(state, {:backfill, _}, %{done?: false, cursor: cursor}), do: %{state | cursor: cursor, source_error: false}
  defp accept(state, {:backfill, _}, %{done?: true}), do: %{state | cursor: nil, mode: :seed, source_error: false}

  defp accept(state, {:scan, _, mode, _}, %{done?: true}) do
    if mode == :seed,
      do:
        Phoenix.PubSub.local_broadcast(
          state.pubsub,
          "topology:world",
          {:bitmap_index_ready, Map.take(state.current, [:dictionary_epoch, :index_epoch])}
        )

    %{
      state
      | mode: :ready,
        cursor: nil,
        scan_due: now() + @scan_interval,
        seeded_at: state.seeded_at || DateTime.utc_now(),
        last_reconciled_at: state.scan_started_at,
        source_error: false
    }
  end

  defp accept(state, {:scan, _, _, _}, %{cursor: cursor}), do: %{state | cursor: cursor, source_error: false}
  defp accept(state, {:catalog, _}, _result), do: %{state | catalog_due: now() + @scan_interval}
  defp accept(state, {:hints, _}, _result), do: state
  defp accept(state, {:dirty, _, _}, _result), do: %{state | dirty: [], source_error: false}
  defp accept(state, _work, _result), do: %{state | source_error: false}

  defp retry(state, work), do: retry(state, work, :down)

  defp retry(state, {:catalog, _sources}, reason) do
    if contention?(reason) do
      schedule(state, @step_interval)
    else
      schedule(%{state | catalog_due: now() + @scan_interval}, @step_interval)
    end
  end

  defp retry(state, {:hints, ids}, reason) do
    state = remember(state, ids)

    if contention?(reason) do
      schedule(state, @step_interval)
    else
      escalate(state)
    end
  end

  defp retry(state, _work, reason) do
    if contention?(reason), do: schedule(state, @step_interval), else: escalate(state)
  end

  defp escalate(state) do
    schedule(%{state | source_error: true, rescan: true, retry_at: now() + 1_000}, 1_000)
  end

  defp contention?(reason) when reason in ["busy", "publisher_busy", "reader_busy", :busy, :publisher_busy, :reader_busy],
    do: true

  defp contention?(_reason), do: false

  defp remember(state, ids) do
    Enum.reduce(ids, state, fn id, state ->
      cond do
        not is_binary(id) or id == "" or MapSet.member?(state.hints, id) ->
          state

        MapSet.size(state.hints) >= @hint_limit or state.hint_bytes + byte_size(id) > @hint_bytes ->
          %{state | rescan: true}

        true ->
          %{state | hints: MapSet.put(state.hints, id), hint_bytes: state.hint_bytes + byte_size(id)}
      end
    end)
  end

  defp disable(state) do
    state = close_resources(state)

    if state.current || state.catalog_sources != [],
      do: schedule(%{state | mode: :closing}, @step_interval),
      else: state
  end

  defp close_resources(state) do
    if state.active do
      Process.exit(state.active.pid, :kill)
      Process.cancel_timer(state.active.timeout)
      Process.demonitor(state.active.ref, [:flush])
    end

    if state.timer, do: Process.cancel_timer(state.timer)

    state = %{
      state
      | active: nil,
        timer: nil,
        mode: :initialize,
        cursor: nil,
        hints: MapSet.new(),
        hint_bytes: 0,
        dirty: [],
        rescan: true,
        seeded_at: nil,
        last_reconciled_at: nil,
        retry_at: nil
    }

    catalogs = BitmapPrefixTags.release(state.catalog_sources)

    current =
      case state.current && Native.bitmap_index_close(state.current.device) do
        {:error, _busy} -> state.current
        _ -> nil
      end

    %{state | current: current, catalog_sources: catalogs, catalog_due: 0}
  end

  defp drain(state, deadline) do
    case close_resources(state) do
      %{current: nil, catalog_sources: []} ->
        :ok

      state ->
        # Dirty NIFs finish after their caller is killed. Retry their bounded
        # work here; a timer addressed to this terminating owner cannot run.
        remaining = deadline - now()

        if remaining > 0 do
          Process.sleep(min(@step_interval, remaining))
          drain(state, deadline)
        else
          Logger.warning("Topology bitmap cleanup exceeded its shutdown budget")
        end
    end
  end

  defp wake(%{active: nil} = state), do: schedule(state, 0)
  defp wake(state), do: state

  defp retry_close(state) do
    state = disable(state)
    if state.mode == :initialize, do: schedule(state, 0), else: state
  end

  defp schedule(state, delay) do
    delay = backoff_delay(state, delay)
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :step, delay)}
  end

  defp backoff_delay(%{retry_at: retry_at}, delay) when is_integer(retry_at) do
    max(delay, max(retry_at - now(), 0))
  end

  defp backoff_delay(_state, delay), do: delay

  defp release(state) do
    Process.cancel_timer(state.active.timeout)
    Process.demonitor(state.active.ref, [:flush])
    %{state | active: nil}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
