defmodule ServiceRadar.Observability.NetflowExporterCacheRefreshWorker do
  @moduledoc """
  Refreshes `platform.netflow_exporter_cache` from recent flow exporter addresses and inventory.

  This is not chart data; it is a background maintenance job to make SRQL dimensions like
  `exporter_name` usable without UI-side joins.
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
  alias ServiceRadar.Observability.NetflowExporterCache
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @seconds_per_day 86_400
  @default_scan_window_seconds 1_800
  @max_scan_window_seconds 3_600
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
    scan_window_seconds = scan_window_seconds(config)
    limit = Keyword.get(config, :limit, @default_limit)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    actor = SystemActor.system(:netflow_exporter_cache_refresh)
    now = DateTime.utc_now()

    sampler_addresses = discover_sampler_addresses(scan_window_seconds, limit)

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

  defp legacy_days_to_seconds(days) when is_integer(days) and days > 0,
    do: days * @seconds_per_day

  defp legacy_days_to_seconds(_days), do: @default_scan_window_seconds

  defp positive_integer_or(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer_or(_value, default), do: default

  defp discover_sampler_addresses(scan_window_seconds, limit)
       when is_integer(scan_window_seconds) and scan_window_seconds > 0 and is_integer(limit) and
              limit > 0 do
    since =
      DateTime.utc_now()
      |> DateTime.add(-scan_window_seconds, :second)
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

  defp discover_sampler_addresses(_scan_window_seconds, _limit), do: []

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
