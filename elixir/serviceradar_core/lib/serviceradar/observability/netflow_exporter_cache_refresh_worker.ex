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
  alias ServiceRadar.Identity.DeviceAliasState
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

  # Two tiers. A sampler address is matched against `ocsf_devices.ip` first, and
  # only the addresses that tier leaves unresolved are looked up against IP
  # aliases.
  #
  # Primary-only matching is why exporters go unattributed: a router commonly
  # exports from an interface that is not its primary address -- one router's
  # primary is 192.168.10.1 while it exports from its WAN address, which is held
  # as a *confirmed alias*. `device_uid` then stays NULL, and because both
  # `flow_device_scope_expr` (rust/srql) and `FlowData.device_flow_samplers/1`
  # match exporters by `device_uid`, that device's own exported flows attribute
  # to nothing and its Flows tab stays empty.
  #
  # Primary wins outright. That ordering is load-bearing: an alias row can name
  # an address another device owns as its primary (routers record neighbours
  # from ARP/next-hop data), and the primary owner is the stronger claim. The
  # primary tier is also unique by construction -- `ocsf_devices_unique_active_ip_idx`
  # is a partial unique index on `ip` for non-deleted rows -- so ambiguity is
  # confined to the alias tier.
  defp load_devices_by_ip(ips, actor) when is_list(ips) do
    by_primary =
      ips
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(%{}, fn chunk, acc ->
        Device
        |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
        |> Ash.Query.filter(expr(ip in ^chunk))
        |> Ash.Query.select([:uid, :ip, :hostname, :name])
        |> read_results(actor)
        |> merge_devices_by_ip(acc)
      end)

    case Enum.reject(ips, &Map.has_key?(by_primary, &1)) do
      [] -> by_primary
      unresolved -> Map.merge(load_devices_by_alias(unresolved, actor), by_primary)
    end
  end

  # Alias tier. Deliberately fails closed: an address claimed by more than one
  # device is skipped, never tie-broken. `device_uid` scopes an entire device's
  # flow view, so a wrong binding does not mis-label one row -- it hands one
  # device another device's whole flow corpus. Leaving it NULL degrades to
  # endpoint-IP matching, which is narrower but never someone else's traffic.
  #
  # `:detected` is excluded, matching the identity subsystem rather than SRQL: a
  # detected alias can carry a single sighting, and one stray observation must
  # not capture a flow corpus.
  defp load_devices_by_alias([], _actor), do: %{}

  defp load_devices_by_alias(ips, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    ips
    |> Enum.chunk_every(2_000)
    |> Enum.reduce(%{}, fn chunk, acc ->
      DeviceAliasState
      |> Ash.Query.filter(
        alias_type == :ip and alias_value in ^chunk and state in [:confirmed, :updated]
      )
      |> Ash.Query.select([:device_id, :alias_value])
      |> read_results(actor)
      |> unambiguous_alias_owners()
      |> resolve_alias_devices(query_opts, actor)
      |> Map.merge(acc)
    end)
  end

  @doc false
  # Public so the fail-closed rule is unit-testable without a database. Takes
  # alias rows and returns only the addresses claimed by exactly one device.
  @spec unambiguous_alias_owners([map()]) :: %{optional(String.t()) => String.t()}
  def unambiguous_alias_owners(rows) when is_list(rows) do
    rows
    |> Enum.group_by(& &1.alias_value, & &1.device_id)
    |> Enum.reduce(%{}, fn {alias_value, device_ids}, acc ->
      case Enum.uniq(device_ids) do
        [device_id] ->
          Map.put(acc, alias_value, device_id)

        contenders ->
          Logger.warning(
            "NetflowExporterCacheRefreshWorker: sampler address claimed by multiple devices; leaving unattributed",
            sampler_address: alias_value,
            device_ids: Enum.sort(contenders)
          )

          :telemetry.execute(
            [:serviceradar, :netflow_exporter_cache, :ambiguous_sampler],
            %{count: 1},
            %{sampler_address: alias_value, device_count: length(contenders)}
          )

          acc
      end
    end)
  end

  # Alias rows outlive their device: the FK to ocsf_devices(uid) keeps them after
  # a soft delete, and the alias table carries no deleted filter. Re-read through
  # the same include_deleted: false path the primary tier uses so a merged-away
  # device cannot claim an exporter.
  defp resolve_alias_devices(owners, _query_opts, _actor) when map_size(owners) == 0, do: %{}

  defp resolve_alias_devices(owners, _query_opts, actor) do
    uids = owners |> Map.values() |> Enum.uniq()

    devices_by_uid =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
      |> Ash.Query.filter(expr(uid in ^uids))
      |> Ash.Query.select([:uid, :ip, :hostname, :name])
      |> read_results(actor)
      |> Map.new(fn device -> {Map.get(device, :uid), device} end)

    Enum.reduce(owners, %{}, fn {alias_value, uid}, acc ->
      case Map.get(devices_by_uid, uid) do
        nil -> acc
        device -> Map.put(acc, alias_value, device)
      end
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
