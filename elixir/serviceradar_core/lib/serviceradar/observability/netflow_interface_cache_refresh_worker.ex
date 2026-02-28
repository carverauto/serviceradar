defmodule ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker do
  @moduledoc """
  Refreshes `platform.netflow_interface_cache` from recent flow interface indices and inventory.

  Flow events store interface indices (ifIndex) in the OCSF payload under:
  - `connection_info.input_snmp`
  - `connection_info.output_snmp`

  This worker extracts `(sampler_address, if_index)` pairs from recent flows, maps exporter IP
  to inventory device, then pulls the latest interface observation for the relevant `if_index`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.NetflowInterfaceCache
  alias ServiceRadar.Observability
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ecto.Query, only: [from: 2]
  import Ash.Expr

  require Ash.Query
  require Logger

  @default_scan_window_days 7
  @default_pair_limit 10_000
  @default_reschedule_seconds 3_600

  @doc """
  Schedules refresh if not already scheduled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      case check_existing_job() do
        true -> {:ok, :already_scheduled}
        false -> %{} |> new() |> ObanSupport.safe_insert()
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
    scan_window_days = Keyword.get(config, :scan_window_days, @default_scan_window_days)
    pair_limit = Keyword.get(config, :pair_limit, @default_pair_limit)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    actor = SystemActor.system(:netflow_interface_cache_refresh)
    now = DateTime.utc_now()

    pairs = discover_interface_pairs(scan_window_days, pair_limit)

    sampler_addresses =
      pairs
      |> Enum.map(fn {ip, _idx} -> ip end)
      |> Enum.uniq()

    devices_by_ip = load_devices_by_ip(sampler_addresses, actor)

    device_pairs = build_device_pairs(pairs, devices_by_ip)

    interface_rows =
      device_pairs
      |> Enum.flat_map(fn {device_uid, %{sampler_address: sampler_address, idxs: idxs}} ->
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

    case Ash.bulk_create(NetflowInterfaceCache, :upsert, attrs,
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

  defp discover_interface_pairs(scan_window_days, limit)
       when is_integer(scan_window_days) and scan_window_days > 0 and is_integer(limit) and
              limit > 0 do
    since =
      DateTime.utc_now()
      |> DateTime.add(-scan_window_days * 86_400, :second)
      |> DateTime.truncate(:second)

    base =
      from(f in "ocsf_network_activity",
        prefix: "platform",
        where: f.time >= ^since,
        where: not is_nil(f.sampler_address),
        where: f.sampler_address != ""
      )

    # Note: interface indices live inside the JSON payload; extract as text, parse safely in Elixir.
    input_q =
      from(f in base,
        select:
          {f.sampler_address, fragment("? #>> '{connection_info,input_snmp}'", f.ocsf_payload)},
        distinct: true,
        limit: ^limit
      )

    output_q =
      from(f in base,
        select:
          {f.sampler_address, fragment("? #>> '{connection_info,output_snmp}'", f.ocsf_payload)},
        distinct: true,
        limit: ^limit
      )

    (Repo.all(input_q) ++ Repo.all(output_q))
    |> Enum.flat_map(fn {sampler_address, idx_txt} ->
      sampler_address = sampler_address |> to_string() |> String.trim()
      idx_txt =
        case idx_txt do
          s when is_binary(s) -> String.trim(s)
          _ -> ""
        end

      with true <- sampler_address != "",
           {idx, ""} <- Integer.parse(idx_txt),
           true <- idx > 0 do
        [{sampler_address, idx}]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp discover_interface_pairs(_scan_window_days, _limit), do: []

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

      read_results(q, actor)
      |> Enum.reduce(acc, fn d, map ->
        case Map.get(d, :ip) do
          ip when is_binary(ip) and ip != "" -> Map.put(map, ip, d)
          _ -> map
        end
      end)
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
