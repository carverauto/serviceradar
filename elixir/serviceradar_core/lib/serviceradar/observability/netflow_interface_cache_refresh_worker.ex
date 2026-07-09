defmodule ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker do
  @moduledoc """
  Refreshes `platform.netflow_interface_cache` from observed flow interface indices and inventory.

  Flow events store interface indices (ifIndex) in the OCSF payload under:
  - `connection_info.input_snmp`
  - `connection_info.output_snmp`

  Flow ingest records `(sampler_address, if_index)` pairs incrementally in
  `netflow_interface_cache`. This worker reads that small dimension table, maps exporter IP to
  inventory device, then pulls the latest interface observation for the relevant `if_index`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Exclude :executing so the self-reschedule in perform/1 isn't deduped
    # against the still-running job (double-seed guarded by check_existing_job).
    unique: [period: :infinity, states: :incomplete]

  import Ash.Expr
  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability
  alias ServiceRadar.Observability.NetflowInterfaceCache
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @seconds_per_day 86_400
  @default_scan_window_seconds 1_800
  @max_scan_window_seconds 3_600
  @default_pair_limit 10_000
  @default_reschedule_seconds 3_600

  @doc """
  Schedules refresh if not already scheduled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    scan_window_seconds = scan_window_seconds(config)
    pair_limit = Keyword.get(config, :pair_limit, @default_pair_limit)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    actor = SystemActor.system(:netflow_interface_cache_refresh)
    now = DateTime.utc_now()

    pairs = discover_interface_pairs(scan_window_seconds, pair_limit)

    sampler_addresses =
      pairs
      |> Enum.map(fn {ip, _idx} -> ip end)
      |> Enum.uniq()

    devices_by_ip = load_devices_by_ip(sampler_addresses, actor)

    device_pairs = build_device_pairs(pairs, devices_by_ip)

    interface_rows =
      Enum.flat_map(device_pairs, fn {device_uid, %{sampler_address: sampler_address, idxs: idxs}} ->
        idxs = MapSet.to_list(idxs)
        latest_interfaces_for_device(device_uid, sampler_address, idxs)
      end)

    attrs =
      Enum.map(interface_rows, fn row ->
        %{
          sampler_address: row.sampler_address,
          if_index: row.if_index,
          device_uid: row.device_uid,
          if_name: row.if_name,
          if_description: row.if_description,
          if_speed_bps: row.if_speed_bps,
          boundary: row.boundary,
          refreshed_at: now
        }
      end)

    case Ash.bulk_create(attrs, NetflowInterfaceCache, :upsert,
           actor: actor,
           domain: Observability,
           return_errors?: true
         ) do
      %Ash.BulkResult{errors: []} ->
        ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 300)))
        :ok

      %Ash.BulkResult{} = result ->
        Logger.warning("NetflowInterfaceCacheRefreshWorker: upsert encountered errors",
          error_count: length(result.errors)
        )

        ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 300)))
        :ok
    end
  end

  defp build_device_pairs(pairs, devices_by_ip) when is_list(pairs) and is_map(devices_by_ip) do
    Enum.reduce(pairs, %{}, fn {sampler_address, if_index}, acc ->
      case Map.get(devices_by_ip, sampler_address) do
        %{uid: device_uid} when is_binary(device_uid) ->
          upsert_device_pair(acc, device_uid, sampler_address, if_index)

        _ ->
          acc
      end
    end)
  end

  defp upsert_device_pair(acc, device_uid, sampler_address, if_index) do
    Map.update(
      acc,
      device_uid,
      %{sampler_address: sampler_address, idxs: MapSet.new([if_index])},
      fn st ->
        %{
          sampler_address: Map.get(st, :sampler_address) || sampler_address,
          idxs: MapSet.put(Map.get(st, :idxs, MapSet.new()), if_index)
        }
      end
    )
  end

  @doc false
  def scan_window_seconds(config) when is_list(config) do
    max_seconds =
      config
      |> Keyword.get(:max_scan_window_seconds, @max_scan_window_seconds)
      |> positive_integer_or(@max_scan_window_seconds)

    seconds =
      case Keyword.get(config, :scan_window_seconds) do
        seconds when is_integer(seconds) and seconds > 0 ->
          seconds

        _ ->
          config
          |> Keyword.get(:scan_window_days)
          |> legacy_days_to_seconds()
          |> positive_integer_or(@default_scan_window_seconds)
      end

    min(seconds, max_seconds)
  end

  def scan_window_seconds(_config), do: @default_scan_window_seconds

  @doc """
  Records observed `(sampler_address, if_index)` pairs from parsed flow rows.

  This is intentionally metadata-light: flow ingest only knows that an exporter reported traffic on
  an ifIndex. The refresh worker later enriches that key with interface inventory.
  """
  @spec record_observed_interface_pairs([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def record_observed_interface_pairs(rows) when is_list(rows) do
    pairs = observed_interface_pairs_from_rows(rows)

    if pairs == [] do
      {:ok, 0}
    else
      now = DateTime.utc_now()

      attrs =
        Enum.map(pairs, fn {sampler_address, if_index} ->
          %{
            sampler_address: sampler_address,
            if_index: if_index,
            refreshed_at: now,
            last_observed_at: now,
            inserted_at: now,
            updated_at: now
          }
        end)

      {count, _} =
        Repo.insert_all("netflow_interface_cache", attrs,
          prefix: "platform",
          conflict_target: [:sampler_address, :if_index],
          on_conflict: {:replace, [:last_observed_at, :updated_at]},
          returning: false
        )

      {:ok, count}
    end
  rescue
    e -> {:error, e}
  end

  def record_observed_interface_pairs(_rows), do: {:ok, 0}

  @doc false
  @spec observed_interface_pairs_from_rows([map()]) :: [{String.t(), pos_integer()}]
  def observed_interface_pairs_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.flat_map(&observed_interface_pairs_from_row/1)
    |> Enum.uniq()
  end

  def observed_interface_pairs_from_rows(_rows), do: []

  defp legacy_days_to_seconds(days) when is_integer(days) and days > 0,
    do: days * @seconds_per_day

  defp legacy_days_to_seconds(_days), do: @default_scan_window_seconds

  defp positive_integer_or(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer_or(_value, default), do: default

  defp discover_interface_pairs(scan_window_seconds, limit)
       when is_integer(scan_window_seconds) and scan_window_seconds > 0 and is_integer(limit) and
              limit > 0 do
    since =
      DateTime.utc_now()
      |> DateTime.add(-scan_window_seconds, :second)
      |> DateTime.truncate(:second)

    query =
      from(c in "netflow_interface_cache",
        prefix: "platform",
        where: c.last_observed_at >= ^since,
        where: not is_nil(c.sampler_address),
        where: c.sampler_address != "",
        where: c.if_index > 0,
        order_by: [desc: c.last_observed_at],
        select: {c.sampler_address, c.if_index},
        limit: ^limit
      )

    query
    |> Repo.all()
    |> Enum.flat_map(&normalize_pair_tuple/1)
    |> Enum.uniq()
  end

  defp discover_interface_pairs(_scan_window_seconds, _limit), do: []

  defp observed_interface_pairs_from_row(row) when is_map(row) do
    sampler_address =
      row
      |> get_value(:sampler_address, "sampler_address")
      |> normalize_sampler_address()

    connection_info =
      row
      |> get_value(:ocsf_payload, "ocsf_payload")
      |> connection_info()

    if is_nil(sampler_address) do
      []
    else
      Enum.reject(
        [
          normalize_pair(sampler_address, get_value(connection_info, :input_snmp, "input_snmp")),
          normalize_pair(sampler_address, get_value(connection_info, :output_snmp, "output_snmp"))
        ],
        &is_nil/1
      )
    end
  end

  defp observed_interface_pairs_from_row(_row), do: []

  defp normalize_pair_tuple({sampler_address, if_index}) do
    case normalize_pair(sampler_address, if_index) do
      nil -> []
      pair -> [pair]
    end
  end

  defp normalize_pair_tuple(_tuple), do: []

  defp normalize_pair(sampler_address, if_index) do
    with sampler_address when is_binary(sampler_address) <-
           normalize_sampler_address(sampler_address),
         if_index when is_integer(if_index) <- normalize_if_index(if_index) do
      {sampler_address, if_index}
    else
      _ -> nil
    end
  end

  defp normalize_sampler_address(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_sampler_address(value) when is_list(value) do
    value
    |> List.to_string()
    |> normalize_sampler_address()
  rescue
    _ -> nil
  end

  defp normalize_sampler_address(_value), do: nil

  # RFC 2863 InterfaceIndex is 1..2147483647; the column is signed int32.
  # Exporters occasionally emit a uint32 ifIndex above int32 max (corrupt data),
  # which would otherwise abort the whole insert_all batch. Drop just that pair.
  @max_if_index 2_147_483_647

  defp normalize_if_index(value) when is_integer(value) and value > 0 and value <= @max_if_index,
    do: value

  # A uint32 ifIndex in 2^31..2^32-1 is out of the RFC 2863 / signed-int32 range
  # — the corruption this clamp exists to absorb. Drop just this pair, but emit a
  # telemetry counter so an exporter shedding interface observations is visible
  # to operators rather than silently dropped. Aggregated by the handler, so this
  # is not per-pair log noise.
  defp normalize_if_index(value) when is_integer(value) and value > @max_if_index do
    :telemetry.execute(
      [:serviceradar, :netflow, :interface_cache, :if_index_out_of_range],
      %{count: 1},
      %{if_index: value}
    )

    nil
  end

  defp normalize_if_index(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {idx, ""} -> normalize_if_index(idx)
      _ -> nil
    end
  end

  defp normalize_if_index(_value), do: nil

  defp connection_info(%{"connection_info" => info}) when is_map(info), do: info
  defp connection_info(%{connection_info: info}) when is_map(info), do: info
  defp connection_info(_payload), do: %{}

  defp get_value(map, atom_key, string_key) when is_map(map) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end

  defp load_devices_by_ip([], _actor), do: %{}

  defp load_devices_by_ip(ips, actor) when is_list(ips) do
    ips
    |> Enum.chunk_every(2_000)
    |> Enum.reduce(%{}, fn chunk, acc ->
      q =
        Device
        |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
        |> Ash.Query.filter(expr(ip in ^chunk))
        |> Ash.Query.select([:uid, :ip])

      q
      |> read_results(actor)
      |> merge_devices_by_ip(acc)
    end)
  end

  defp merge_devices_by_ip(devices, acc) when is_list(devices) and is_map(acc) do
    Enum.reduce(devices, acc, fn d, map ->
      with ip when is_binary(ip) <- Map.get(d, :ip),
           true <- ip != "" do
        Map.put(map, ip, d)
      else
        _ -> map
      end
    end)
  end

  defp latest_interfaces_for_device(device_uid, sampler_address, idxs)
       when is_binary(device_uid) and is_binary(sampler_address) and is_list(idxs) and idxs != [] do
    # We want the latest observation per if_index. Use DISTINCT ON (if_index) ordering by timestamp desc.
    query =
      from(i in "discovered_interfaces",
        prefix: "platform",
        where: i.device_id == ^device_uid,
        where: i.if_index in ^idxs,
        distinct: i.if_index,
        order_by: [asc: i.if_index, desc: i.timestamp],
        select: %{
          if_index: i.if_index,
          if_name: i.if_name,
          if_description: i.if_descr,
          if_speed_bps: i.speed_bps
        }
      )

    rows = Repo.all(query)

    Enum.map(rows, fn r ->
      %{
        sampler_address: sampler_address,
        device_uid: device_uid,
        if_index: r.if_index,
        if_name: r.if_name,
        if_description: r.if_description,
        if_speed_bps: r.if_speed_bps,
        boundary: nil
      }
    end)
  end

  defp latest_interfaces_for_device(_device_uid, _sampler_address, _idxs), do: []

  defp read_results(query, actor) do
    case Ash.read(query, actor: actor) do
      {:ok, devices} when is_list(devices) -> devices
      {:ok, %{results: results}} when is_list(results) -> results
      _ -> []
    end
  end
end
