defmodule ServiceRadar.Observability.IpEnrichmentRefreshWorker do
  @moduledoc """
  Background job that refreshes IP enrichment caches (rDNS + GeoIP/ASN, plus optional ipinfo).

  This worker is intentionally SRQL-driven:
  - it discovers candidate IPs via SRQL flow stats queries
  - it stores enrichment in cache tables keyed by IP with TTL

  Important constraints:
  - SRQL query execution must never make external API calls
  - GeoIP/ASN enrichment is performed via local MMDB databases (GeoLite2) and cached
  - ipinfo enrichment (when enabled) is also MMDB-based and cached (no per-IP HTTP calls)
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor

  alias ServiceRadar.Observability.{
    GeoIP,
    IpGeoEnrichmentCache,
    IpInfo,
    IpIpinfoCache,
    IpRdnsCache,
    NetflowSettings,
    SRQLRunner
  }

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ecto.Query, only: [from: 2]

  require Ash.Query
  require Logger

  @default_scan_window "last_1h"
  @default_limit 200
  @default_rdns_ttl_seconds 86_400
  @default_geo_ttl_seconds 604_800
  @default_ipinfo_ttl_seconds 604_800
  @default_rdns_timeout_ms 250
  @default_ipinfo_timeout_ms 800
  @default_reschedule_seconds 300

  @doc """
  Schedules enrichment refresh if not already scheduled.
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
    scan_window = Keyword.get(config, :scan_window, @default_scan_window)
    limit = Keyword.get(config, :limit, @default_limit)
    rdns_ttl_seconds = Keyword.get(config, :rdns_ttl_seconds, @default_rdns_ttl_seconds)
    geo_ttl_seconds = Keyword.get(config, :geo_ttl_seconds, @default_geo_ttl_seconds)
    ipinfo_ttl_seconds = Keyword.get(config, :ipinfo_ttl_seconds, @default_ipinfo_ttl_seconds)
    rdns_timeout_ms = Keyword.get(config, :rdns_timeout_ms, @default_rdns_timeout_ms)
    ipinfo_timeout_ms = Keyword.get(config, :ipinfo_timeout_ms, @default_ipinfo_timeout_ms)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    now = DateTime.utc_now()
    rdns_expires_at = DateTime.add(now, rdns_ttl_seconds, :second)
    geo_expires_at = DateTime.add(now, geo_ttl_seconds, :second)
    ipinfo_expires_at = DateTime.add(now, ipinfo_ttl_seconds, :second)

    actor = SystemActor.system(:ip_enrichment_refresh)

    settings = load_netflow_settings(actor)
    geoip_enabled = geoip_enabled?(settings)
    record_ip_enrichment_attempt(settings, actor, now)

    try do
      ips = discover_candidate_ips(scan_window, limit)

      Enum.each(ips, fn ip ->
        refresh_rdns(ip, actor, now, rdns_expires_at, rdns_timeout_ms)

        if geoip_enabled do
          refresh_geo(ip, actor, now, geo_expires_at)
        end

        refresh_ipinfo(ip, settings, actor, now, ipinfo_expires_at, ipinfo_timeout_ms)
      end)

      record_ip_enrichment_success(settings, actor, now)
      ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 30)))
      :ok
    rescue
      e ->
        record_ip_enrichment_failure(settings, actor, now, e)
        reraise e, __STACKTRACE__
    end
  end

  defp discover_candidate_ips(scan_window, limit) do
    base = "in:flows time:#{scan_window}"

    src_query =
      ~s|#{base} stats:"sum(bytes_total) as total_bytes by src_endpoint_ip" sort:total_bytes:desc limit:#{limit}|

    dst_query =
      ~s|#{base} stats:"sum(bytes_total) as total_bytes by dst_endpoint_ip" sort:total_bytes:desc limit:#{limit}|

    src_ips = extract_ips(SRQLRunner.query(src_query), "src_endpoint_ip")
    dst_ips = extract_ips(SRQLRunner.query(dst_query), "dst_endpoint_ip")

    (src_ips ++ dst_ips)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", "—", "-", "Unknown"]))
    |> Enum.uniq()
  end

  defp extract_ips({:ok, rows}, key) when is_list(rows) and is_binary(key) do
    Enum.flat_map(rows, fn
      %{^key => ip} when is_binary(ip) -> [ip]
      %{"result" => %{} = payload} -> extract_ips({:ok, [payload]}, key)
      %{} -> []
      _ -> []
    end)
  end

  defp extract_ips(_other, _key), do: []

  defp refresh_rdns(ip, actor, now, expires_at, timeout_ms) when is_binary(ip) do
    {hostname, status, err} = rdns_lookup(ip, timeout_ms)

    existing_error_count = existing_error_count(IpRdnsCache, ip, actor)

    error_count =
      if is_nil(err),
        do: 0,
        else: existing_error_count + 1

    attrs = %{
      ip: ip,
      hostname: hostname,
      status: status,
      looked_up_at: now,
      expires_at: expires_at,
      error: err,
      error_count: error_count
    }

    changeset =
      IpRdnsCache
      |> Ash.Changeset.for_create(:upsert, attrs)

    case Ash.create(changeset, actor: actor) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("IpEnrichmentRefreshWorker: failed to upsert rDNS cache",
          ip: ip,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp refresh_geo(ip, actor, now, expires_at) when is_binary(ip) do
    {attrs, status, err} = geo_lookup(ip)
    upsert_geo_cache(ip, attrs, status, err, actor, now, expires_at)
  end

  defp geo_lookup(ip) when is_binary(ip) do
    if private_ip?(ip) do
      {%{is_private: true}, "private", nil}
    else
      case GeoIP.lookup(ip) do
        {:ok, data} when is_map(data) ->
          {Map.put(data, :is_private, false), "ok", nil}

        {:error, reason} ->
          {%{is_private: false}, "error", inspect(reason)}
      end
    end
  end

  defp upsert_geo_cache(ip, attrs, status, err, actor, now, expires_at)
       when is_binary(ip) and is_map(attrs) do
    existing_error_count = existing_error_count(IpGeoEnrichmentCache, ip, actor)
    error_count = if is_nil(err), do: 0, else: existing_error_count + 1

    attrs =
      attrs
      |> Map.merge(%{
        ip: ip,
        looked_up_at: now,
        expires_at: expires_at,
        error: err,
        error_count: error_count
      })

    changeset =
      IpGeoEnrichmentCache
      |> Ash.Changeset.for_create(:upsert, attrs)

    case Ash.create(changeset, actor: actor) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("IpEnrichmentRefreshWorker: failed to upsert GeoIP/ASN cache",
          ip: ip,
          status: status,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp existing_error_count(resource, ip, actor) do
    query = resource |> Ash.Query.for_read(:by_ip, %{ip: ip})

    case Ash.read_one(query, actor: actor) do
      {:ok, %{error_count: n}} when is_integer(n) -> n
      _ -> 0
    end
  end

  defp load_netflow_settings(actor) do
    case NetflowSettings.get_settings(actor: actor) do
      {:ok, %NetflowSettings{} = settings} ->
        settings

      _ ->
        # In some environments the default singleton row may not exist yet.
        case NetflowSettings.create(%{}, actor: actor) do
          {:ok, %NetflowSettings{} = settings} -> settings
          _ -> nil
        end
    end
  end

  defp geoip_enabled?(%NetflowSettings{geoip_enabled: false}), do: false
  defp geoip_enabled?(_), do: true

  defp record_ip_enrichment_attempt(nil, _actor, _now), do: :ok

  defp record_ip_enrichment_attempt(%NetflowSettings{} = settings, actor, %DateTime{} = now) do
    _ =
      NetflowSettings.update_enrichment_status(
        settings,
        %{ip_enrichment_last_attempt_at: now},
        actor: actor
      )

    :ok
  end

  defp record_ip_enrichment_success(nil, _actor, _now), do: :ok

  defp record_ip_enrichment_success(%NetflowSettings{} = settings, actor, %DateTime{} = now) do
    _ =
      NetflowSettings.update_enrichment_status(
        settings,
        %{ip_enrichment_last_success_at: now, ip_enrichment_last_error: nil},
        actor: actor
      )

    :ok
  end

  defp record_ip_enrichment_failure(nil, _actor, _now, _e), do: :ok

  defp record_ip_enrichment_failure(%NetflowSettings{} = settings, actor, %DateTime{} = _now, e) do
    _ =
      NetflowSettings.update_enrichment_status(
        settings,
        %{ip_enrichment_last_error: Exception.message(e)},
        actor: actor
      )

    Logger.warning("IpEnrichmentRefreshWorker: failed", error: Exception.message(e))
    :ok
  end

  defp refresh_ipinfo(_ip, nil, _actor, _now, _expires_at, _timeout_ms), do: :skip

  defp refresh_ipinfo(ip, %NetflowSettings{} = settings, actor, now, expires_at, timeout_ms)
       when is_binary(ip) do
    # Background-only enrichment: never call external APIs during SRQL query execution.
    if ipinfo_enabled_for_ip?(settings, ip) do
      {attrs, err} = ipinfo_lookup(ip, timeout_ms)

      upsert_ipinfo_cache(ip, attrs, err, actor, now, expires_at)
    else
      :skip
    end
  end

  defp ipinfo_enabled_for_ip?(%NetflowSettings{} = settings, ip) when is_binary(ip) do
    settings.ipinfo_enabled and IpInfo.available?() and not private_ip?(ip)
  end

  defp upsert_ipinfo_cache(ip, attrs, err, actor, now, expires_at) when is_binary(ip) do
    existing_error_count = existing_error_count(IpIpinfoCache, ip, actor)
    error_count = if is_nil(err), do: 0, else: existing_error_count + 1

    attrs =
      (attrs || %{})
      |> Map.merge(%{
        ip: ip,
        looked_up_at: now,
        expires_at: expires_at,
        error: err,
        error_count: error_count
      })

    changeset =
      IpIpinfoCache
      |> Ash.Changeset.for_create(:upsert, attrs)

    case Ash.create(changeset, actor: actor) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("IpEnrichmentRefreshWorker: failed to upsert ipinfo cache",
          ip: ip,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp ipinfo_lookup(ip, timeout_ms) when is_binary(ip) and is_integer(timeout_ms) do
    # Local-only: do not perform per-IP HTTP calls.
    task =
      Task.async(fn ->
        IpInfo.lookup(ip)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{} = attrs}} ->
        {attrs, nil}

      {:ok, {:error, reason}} ->
        {nil, inspect(reason)}

      nil ->
        {nil, "timeout"}

      other ->
        {nil, inspect(other)}
    end
  end

  defp rdns_lookup(ip, timeout_ms) when is_binary(ip) and is_integer(timeout_ms) do
    with {:ok, ip_tuple} <- parse_ip(ip) do
      task =
        Task.async(fn ->
          # Uses system resolver; wrapped in a strict timeout at the process level.
          case :inet.gethostbyaddr(ip_tuple) do
            {:ok, {:hostent, hostname, _aliases, _addrtype, _len, _addrs}} ->
              {:ok, hostname}

            {:error, reason} ->
              {:error, reason}
          end
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, hostname}} ->
          {to_string(hostname), "ok", nil}

        {:ok, {:error, reason}} ->
          {nil, "error", inspect(reason)}

        nil ->
          {nil, "timeout", "timeout"}
      end
    else
      {:error, reason} ->
        {nil, "error", reason}
    end
  end

  defp rdns_lookup(_ip, _timeout_ms), do: {nil, "error", "invalid_ip"}

  defp parse_ip(ip) when is_binary(ip) do
    ip = ip |> String.trim() |> String.split("/", parts: 2) |> List.first()

    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> {:error, "invalid_ip"}
    end
  end

  defp private_ip?(ip) when is_binary(ip) do
    ip = normalize_ip_string(ip)

    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> private_ip_tuple?(tuple)
      {:error, _} -> false
    end
  end

  defp private_ip?(_), do: false

  defp normalize_ip_string(ip) when is_binary(ip) do
    ip
    |> String.trim()
    |> String.split("/", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  defp private_ip_tuple?({10, _, _, _}), do: true
  defp private_ip_tuple?({127, _, _, _}), do: true
  defp private_ip_tuple?({169, 254, _, _}), do: true
  defp private_ip_tuple?({192, 168, _, _}), do: true
  defp private_ip_tuple?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip_tuple?({0, _, _, _}), do: true
  defp private_ip_tuple?({_, _, _, _}), do: false

  defp private_ip_tuple?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # fc00::/7 (unique local addresses)
  defp private_ip_tuple?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  # fe80::/10 (link-local)
  defp private_ip_tuple?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  defp private_ip_tuple?(_), do: false
end
