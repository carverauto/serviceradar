defmodule ServiceRadarWebNG.Topology.Scale.Meter do
  @moduledoc false
  use GenServer

  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.WorldCache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def report, do: GenServer.call(__MODULE__, :report, 5_000)

  def init(nil) do
    Process.flag(:trap_exit, true)
    table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]
    :ok = :telemetry.attach(__MODULE__, event, &__MODULE__.query/4, table)
    send(self(), :sample)
    {:ok, %{table: table, event: event, samples: 0, peaks: %{}, latest: %{}}}
  end

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
    attached = Enum.any?(:telemetry.list_handlers(state.event), &(&1.id == __MODULE__))

    {:reply, %{samples: state.samples, peaks: state.peaks, latest: memory(), database: db, instrumented: attached}, state}
  end

  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)

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
