defmodule ServiceRadarWebNG.Topology.Scale.Meter do
  @moduledoc false
  use GenServer

  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.WorldCache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def report, do: GenServer.call(__MODULE__, :report, 5_000)

  @busy [:serviceradar, :topology, :bitmap_query, :busy]
  @admission [:serviceradar, :topology, :bitmap_query, :admission]
  @work [:serviceradar, :topology, :bitmap_index, :work]
  @overflow [:serviceradar, :topology, :bitmap_index, :hint_overflow]

  def init(nil) do
    Process.flag(:trap_exit, true)
    table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]
    :ok = :telemetry.attach(__MODULE__, event, &__MODULE__.query/4, table)
    queries = :ets.new(__MODULE__.Queries, [:set, :public, write_concurrency: true])
    :ok = :telemetry.attach_many(__MODULE__.Queries, [@busy, @admission], &__MODULE__.bitmap/4, queries)
    publisher = :ets.new(__MODULE__.Publisher, [:set, :public, write_concurrency: true])
    :ok = :telemetry.attach_many(__MODULE__.Publisher, [@work, @overflow], &__MODULE__.publisher/4, publisher)
    send(self(), :sample)
    {:ok, %{table: table, queries: queries, publisher: publisher, event: event, samples: 0, peaks: %{}, latest: %{}}}
  end

  # Fixed operation/mode/outcome labels survive index restarts in this VM.
  def publisher(@work, %{elapsed_ms: elapsed}, %{work: work, mode: mode, outcome: outcome}, table) do
    key = {:work, mode, work, outcome}
    :ets.update_counter(table, key, [{2, 1}, {3, elapsed}], {key, 0, 0})
  end

  def publisher(@overflow, %{count: count, limit: limit}, %{limit_kind: kind}, table) do
    key = {:overflow, kind}
    :ets.update_counter(table, key, {2, count}, {key, 0, limit})
  end

  # Fixed source atoms and power-of-two millisecond buckets keep this bounded.
  def bitmap(@busy, _measurements, %{source: source}, table),
    do: :ets.update_counter(table, {:busy, source}, 1, {{:busy, source}, 0})

  def bitmap(@admission, %{wait_ms: wait, run_ms: run}, _metadata, table) do
    for {kind, ms} <- [wait_ms: wait, run_ms: run] do
      key = {kind, bucket(ms)}
      :ets.update_counter(table, key, 1, {key, 0})
    end
  end

  defp bucket(ms) when ms < 1, do: 0
  defp bucket(ms), do: min(Integer.pow(2, ceil(:math.log2(ms + 1))), 2_048)

  def query(_event, timing, metadata, table) do
    sql = to_string(metadata.query)

    bucket =
      cond do
        metadata[:options][:topology_operation] == :bitmap_addresses -> :addresses
        String.contains?(sql, "device_fleet_ordinals") -> :dictionary
        String.contains?(sql, "ocsf_devices") -> :inventory
        String.contains?(sql, "users") or String.contains?(sql, "role_profiles") -> :authority
        true -> :other
      end

    # Transaction statements report num_rows nil, and Ecto omits or nils
    # timings it did not measure; either would otherwise detach this handler.
    rows =
      case metadata.result do
        {:ok, %{num_rows: rows}} when is_integer(rows) -> rows
        _ -> 0
      end

    timings =
      Enum.map(
        [:query_time, :decode_time, :queue_time],
        &System.convert_time_unit(Map.get(timing, &1) || 0, :native, :microsecond)
      )

    [query, decode, queue] = timings
    increments = [{2, 1}, {3, rows}, {4, query}, {5, decode}, {6, queue}]
    :ets.update_counter(table, bucket, increments, {bucket, 0, 0, 0, 0, 0})
  end

  def handle_info(:sample, state) do
    latest = memory()
    peaks = Map.merge(state.peaks, latest, fn _key, a, b -> max(a, b) end)
    Process.send_after(self(), :sample, 1_000)
    {:noreply, %{state | samples: state.samples + 1, peaks: peaks, latest: latest}}
  end

  def handle_call(:report, _from, state) do
    db =
      Map.new(:ets.tab2list(state.table), fn {key, count, rows, query, decode, queue} ->
        {key, %{queries: count, rows: rows, query_us: query, decode_us: decode, queue_us: queue}}
      end)

    # A detached handler leaves stale counters behind; report it so they cannot pass.
    attached =
      Enum.any?(:telemetry.list_handlers(state.event), &(&1.id == __MODULE__)) and
        Enum.all?([@busy, @admission], fn event ->
          Enum.any?(:telemetry.list_handlers(event), &(&1.id == __MODULE__.Queries))
        end) and
        Enum.all?([@work, @overflow], fn event ->
          Enum.any?(:telemetry.list_handlers(event), &(&1.id == __MODULE__.Publisher))
        end)

    queries =
      Enum.reduce(:ets.tab2list(state.queries), %{busy: %{}, wait_ms: %{}, run_ms: %{}}, fn {{kind, key}, count}, acc ->
        put_in(acc, [kind, key], count)
      end)

    {:reply,
     %{
       samples: state.samples,
       peaks: state.peaks,
       latest: memory(),
       database: db,
       queries: queries,
       publisher: publisher_report(state.publisher),
       instrumented: attached
     }, state}
  end

  def terminate(_reason, _state) do
    :telemetry.detach(__MODULE__)
    :telemetry.detach(__MODULE__.Queries)
    :telemetry.detach(__MODULE__.Publisher)
  end

  defp publisher_report(table) do
    table
    |> :ets.tab2list()
    |> Enum.sort()
    |> Enum.reduce(%{work: [], hint_overflow: %{}}, fn
      {{:work, mode, work, outcome}, count, elapsed}, acc ->
        row = %{mode: mode, work: work, outcome: outcome, count: count, elapsed_ms: elapsed}
        Map.update!(acc, :work, &[row | &1])

      {{:overflow, kind}, count, limit}, acc ->
        put_in(acc, [:hint_overflow, kind], %{count: count, limit: limit})
    end)
  end

  def memory do
    beam = Map.new(:erlang.memory())

    base = %{
      beam_total: beam.total,
      beam_binary: beam.binary,
      process_count: length(Process.list()),
      rss: proc_bytes("VmRSS"),
      rss_high_water: proc_bytes("VmHWM"),
      mailbox_messages:
        Enum.reduce(Process.list(), 0, fn pid, total ->
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, count} -> total + count
            nil -> total
          end
        end)
    }

    native =
      with {:ok, snapshot} <- BitmapIndex.snapshot(), {:ok, status} <- Native.bitmap_index_status(snapshot.device) do
        %{
          native_bytes: status.native_bytes,
          native_peak_bytes: status.peak_bytes,
          pins: status.pins,
          pending_dirty: snapshot.progress.pending_dirty,
          pending_hints: snapshot.progress.pending_hints,
          pending_hint_bytes: snapshot.progress.pending_hint_bytes,
          pending_hint_retained_bytes: snapshot.progress.pending_hint_retained_bytes,
          pending_hint_age_ms: snapshot.progress.pending_hint_age_ms,
          pending_native: snapshot.progress.pending_native,
          pending_publish: snapshot.progress.pending_publish,
          pending_publish_age_ms: snapshot.progress.pending_publish_age_ms,
          native_unavailable: 0
        }
      else
        _ -> %{native_unavailable: 1}
      end

    mapping =
      case current_world() do
        {:ok, %{ordinals: %{info: info}}} -> %{current_mapping_bytes: info.retained_bytes, mapping_unavailable: 0}
        _ -> %{mapping_unavailable: 1}
      end

    base |> Map.merge(native) |> Map.merge(mapping)
  end

  defp current_world do
    WorldCache.world()
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp proc_bytes(field) do
    case Regex.run(~r/^#{field}:\s+(\d+) kB$/m, File.read!("/proc/self/status")) do
      [_, value] -> String.to_integer(value) * 1024
      _ -> raise "missing Linux memory metric #{field}"
    end
  end
end
