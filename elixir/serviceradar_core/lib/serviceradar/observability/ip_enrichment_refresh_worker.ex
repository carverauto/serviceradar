defmodule ServiceRadar.Observability.IpEnrichmentRefreshWorker do
  @moduledoc """
  Background job that refreshes IP enrichment caches (rDNS now; GeoIP/ASN later).

  This worker is intentionally SRQL-driven:
  - it discovers candidate IPs via SRQL flow stats queries
  - it stores enrichment in cache tables keyed by IP with TTL
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.{
    GeoIP,
    IpGeoEnrichmentCache,
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

    ips = discover_candidate_ips(scan_window, limit)
    Enum.each(ips, fn ip ->
      refresh_rdns(ip, actor, now, rdns_expires_at, rdns_timeout_ms)
      refresh_geo(ip, actor, now, geo_expires_at)
      refresh_ipinfo(ip, settings, actor, now, ipinfo_expires_at, ipinfo_timeout_ms)
    end)

    ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 30)))
    :ok
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

    existing_error_count =
      case Ash.read_one(IpRdnsCache |> Ash.Query.for_read(:by_ip, %{ip: ip}), actor: actor) do
        {:ok, %IpRdnsCache{error_count: n}} when is_integer(n) -> n
        _ -> 0
      end

    error_count =
      cond do
        is_nil(err) -> 0
        true -> existing_error_count + 1
      end

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
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("IpEnrichmentRefreshWorker: failed to upsert rDNS cache",
          ip: ip,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp refresh_geo(ip, actor, now, expires_at) when is_binary(ip) do
    is_private = private_ip?(ip)

    {attrs, status, err} =
      if is_private do
        {%{is_private: true}, "private", nil}
      else
        case GeoIP.lookup(ip) do
          {:ok, data} when is_map(data) ->
            {Map.put(data, :is_private, false), "ok", nil}

          {:error, reason} ->
            {%{is_private: false}, "error", inspect(reason)}
        end
      end

    existing_error_count =
      case Ash.read_one(
             IpGeoEnrichmentCache |> Ash.Query.for_read(:by_ip, %{ip: ip}),
             actor: actor
           ) do
        {:ok, %IpGeoEnrichmentCache{error_count: n}} when is_integer(n) -> n
        _ -> 0
      end

    error_count =
      cond do
        is_nil(err) -> 0
        true -> existing_error_count + 1
      end

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
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("IpEnrichmentRefreshWorker: failed to upsert GeoIP/ASN cache",
          ip: ip,
          status: status,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp load_netflow_settings(actor) do
    case NetflowSettings.get_settings(actor: actor) do
      {:ok, %NetflowSettings{} = settings} -> settings
      _ -> nil
    end
  end

  defp refresh_ipinfo(_ip, nil, _actor, _now, _expires_at, _timeout_ms), do: :skip

  defp refresh_ipinfo(ip, %NetflowSettings{} = settings, actor, now, expires_at, timeout_ms)
       when is_binary(ip) do
    # Background-only enrichment: never call external APIs during SRQL query execution.
    if settings.ipinfo_enabled && is_binary(settings.ipinfo_api_key) && settings.ipinfo_api_key != "" &&
         not private_ip?(ip) do
      {attrs, err} = ipinfo_lookup(ip, settings.ipinfo_base_url, settings.ipinfo_api_key, timeout_ms)

      existing_error_count =
        case Ash.read_one(
               IpIpinfoCache |> Ash.Query.for_read(:by_ip, %{ip: ip}),
               actor: actor
             ) do
          {:ok, %IpIpinfoCache{error_count: n}} when is_integer(n) -> n
          _ -> 0
        end

      error_count =
        cond do
          is_nil(err) -> 0
          true -> existing_error_count + 1
        end

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
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.warning("IpEnrichmentRefreshWorker: failed to upsert ipinfo cache",
            ip: ip,
            reason: inspect(reason)
          )

          :error
      end
    else
      :skip
    end
  end

  defp ipinfo_lookup(ip, base_url, token, timeout_ms)
       when is_binary(ip) and is_binary(base_url) and is_binary(token) and is_integer(timeout_ms) do
    base_url = String.trim(base_url || "")
    token = String.trim(token || "")

    if base_url == "" or token == "" do
      {nil, "missing_ipinfo_config"}
    else
      url =
        base_url
        |> String.trim_trailing("/")
        |> Kernel.<>("/lite/")
        |> Kernel.<>(URI.encode(ip))
        |> Kernel.<>("?token=")
        |> Kernel.<>(URI.encode(token))

      task =
        Task.async(fn ->
          req = Finch.build(:get, url)

          case Finch.request(req, ServiceRadar.Finch, receive_timeout: timeout_ms) do
            {:ok, %Finch.Response{status: 200, body: body}} ->
              case Jason.decode(body) do
                {:ok, %{} = data} -> {:ok, data}
                _ -> {:error, :invalid_json}
              end

            {:ok, %Finch.Response{status: status, body: body}} ->
              {:error, {:http_status, status, body}}

            {:error, reason} ->
              {:error, reason}
          end
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, %{} = data}} ->
          {normalize_ipinfo_data(data), nil}

        {:ok, {:error, reason}} ->
          {nil, inspect(reason)}

        nil ->
          {nil, "timeout"}
      end
    end
  end

  defp normalize_ipinfo_data(%{} = data) do
    asn =
      case Map.get(data, "asn") do
        "AS" <> rest ->
          case Integer.parse(rest) do
            {n, ""} -> n
            _ -> nil
          end

        _ ->
          nil
      end

    %{
      country_code: Map.get(data, "country_code"),
      country_name: Map.get(data, "country"),
      region: Map.get(data, "region"),
      city: Map.get(data, "city"),
      timezone: Map.get(data, "timezone"),
      as_number: asn,
      as_name: Map.get(data, "as_name"),
      as_domain: Map.get(data, "as_domain")
    }
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
    ip = ip |> String.trim() |> String.split("/", parts: 2) |> List.first()

    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {127, _, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {172, b, _, _}} when b in 16..31 -> true
      {:ok, {0, _, _, _}} -> true
      {:ok, {_, _, _, _}} -> false
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      # fc00::/7 (unique local addresses)
      {:ok, {a, _, _, _, _, _, _, _}} when a in 0xFC00..0xFDFF -> true
      # fe80::/10 (link-local)
      {:ok, {a, _, _, _, _, _, _, _}} when a in 0xFE80..0xFEBF -> true
      {:ok, _} -> false
      {:error, _} -> false
    end
  end

  defp private_ip?(_), do: false
end
