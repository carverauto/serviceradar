defmodule ServiceRadar.Observability.NetflowExporterCacheRefreshWorker do
  @moduledoc """
  Refreshes `platform.netflow_exporter_cache` from recent flow exporter addresses and inventory.

  This is not chart data; it is a background maintenance job to make SRQL dimensions like
  `exporter_name` usable without UI-side joins.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  import Ash.Expr
  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability
  alias ServiceRadar.Observability.NetflowExporterCache
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_scan_window_days 7
  @default_limit 5_000
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
    scan_window_days = Keyword.get(config, :scan_window_days, @default_scan_window_days)
    limit = Keyword.get(config, :limit, @default_limit)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    actor = SystemActor.system(:netflow_exporter_cache_refresh)
    now = DateTime.utc_now()

    sampler_addresses = discover_sampler_addresses(scan_window_days, limit)

    devices_by_ip = load_devices_by_ip(sampler_addresses, actor)

    attrs =
      Enum.map(sampler_addresses, fn ip ->
        device = Map.get(devices_by_ip, ip)

        %{
          sampler_address: ip,
          exporter_name: exporter_name(ip, device),
          device_uid: device && Map.get(device, :uid),
          refreshed_at: now
        }
      end)

    case Ash.bulk_create(attrs, NetflowExporterCache, :upsert,
           actor: actor,
           domain: Observability,
           return_errors?: true
         ) do
      %Ash.BulkResult{errors: []} ->
        ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 300)))
        :ok

      %Ash.BulkResult{} = result ->
        Logger.warning("NetflowExporterCacheRefreshWorker: upsert encountered errors",
          error_count: length(result.errors)
        )

        ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 300)))
        :ok
    end
  end

  defp discover_sampler_addresses(scan_window_days, limit)
       when is_integer(scan_window_days) and scan_window_days > 0 and is_integer(limit) and
              limit > 0 do
    since =
      DateTime.utc_now()
      |> DateTime.add(-scan_window_days * 86_400, :second)
      |> DateTime.truncate(:second)

    query =
      from(f in "ocsf_network_activity",
        prefix: "platform",
        where: f.time >= ^since,
        where: not is_nil(f.sampler_address),
        where: f.sampler_address != "",
        distinct: true,
        select: f.sampler_address,
        limit: ^limit
      )

    query
    |> Repo.all()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp discover_sampler_addresses(_scan_window_days, _limit), do: []

  defp load_devices_by_ip([], _actor), do: %{}

  defp load_devices_by_ip(ips, actor) when is_list(ips) do
    ips
    |> Enum.chunk_every(2_000)
    |> Enum.reduce(%{}, fn chunk, acc ->
      q =
        Device
        |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
        |> Ash.Query.filter(expr(ip in ^chunk))
        |> Ash.Query.select([:uid, :ip, :hostname, :name])

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

  defp read_results(query, actor) do
    case Ash.read(query, actor: actor) do
      {:ok, devices} when is_list(devices) -> devices
      {:ok, %{results: results}} when is_list(results) -> results
      _ -> []
    end
  end

  defp exporter_name(ip, nil) when is_binary(ip), do: ip

  defp exporter_name(ip, device) when is_binary(ip) and is_map(device) do
    (Map.get(device, :hostname) || Map.get(device, :name) || ip)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> ip
      s -> s
    end
  end
end
