defmodule ServiceRadar.Observability.NetflowSecurityRefreshWorker do
  @moduledoc """
  Refreshes optional NetFlow security intelligence caches.

  This worker is intentionally SRQL-driven for metric discovery/aggregation.
  It writes to bounded cache tables for cheap UI lookups.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 120, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.{
    IpThreatIntelCache,
    NetflowPortAnomalyFlag,
    NetflowPortScanFlag,
    NetflowSettings,
    SRQLRunner
  }

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ecto.Query, only: [from: 2]

  require Logger

  @default_scan_window_token "last_5m"
  @default_limit 200
  @default_reschedule_seconds 300
  @default_cache_ttl_seconds 900

  @doc """
  Schedules the refresh job if not already scheduled.
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
    limit = Keyword.get(config, :limit, @default_limit)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)
    cache_ttl_seconds = Keyword.get(config, :cache_ttl_seconds, @default_cache_ttl_seconds)

    now = DateTime.utc_now()
    cache_expires_at = DateTime.add(now, cache_ttl_seconds, :second)
    actor = SystemActor.system(:netflow_security_refresh)

    settings =
      case NetflowSettings.get_settings(actor: actor) do
        {:ok, %NetflowSettings{} = s} -> s
        _ -> nil
      end

    if is_nil(settings) do
      ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 30)))
      :ok
    else
      maybe_refresh_threat(settings, actor, now, cache_expires_at, limit)
      maybe_refresh_port_scan(settings, actor, now, cache_expires_at, limit)
      maybe_refresh_anomalies(settings, actor, now, cache_expires_at, limit)

      ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 30)))
      :ok
    end
  end

  defp maybe_refresh_threat(%NetflowSettings{threat_intel_enabled: true} = settings, actor, now, expires_at, limit) do
    # Use flows to discover the IPs we should care about.
    ips = discover_candidate_ips("last_1h", limit)

    # For now, keep matching simple: if threat intel is enabled, mark IPs as matched if any
    # indicator contains the IP. We do the match via SQL for index-backed CIDR containment.
    matches = threat_matches_for_ips(ips)

    Enum.each(matches, fn {ip, match_count, max_severity, sources} ->
      changeset =
        Ash.Changeset.for_create(IpThreatIntelCache, :upsert, %{
          ip: ip,
          matched: match_count > 0,
          match_count: match_count,
          max_severity: max_severity,
          sources: sources,
          looked_up_at: now,
          expires_at: expires_at,
          error: nil,
          error_count: 0
        })

      _ = Ash.create(changeset, actor: actor)
    end)

    Logger.debug("Threat intel cache refreshed",
      enabled: settings.threat_intel_enabled,
      ip_count: length(ips)
    )
  end

  defp maybe_refresh_threat(_settings, _actor, _now, _expires_at, _limit), do: :skip

  defp maybe_refresh_port_scan(
         %NetflowSettings{
           port_scan_enabled: true,
           port_scan_window_seconds: window_seconds,
           port_scan_unique_ports_threshold: threshold
         },
         actor,
         now,
         expires_at,
         limit
       ) do
    time_token = window_seconds_to_token(window_seconds)

    q =
      ~s|in:flows time:#{time_token} stats:"count_distinct(dst_endpoint_port) as unique_ports by src_endpoint_ip" sort:unique_ports:desc limit:#{limit}|

    rows = SRQLRunner.query(q) |> unwrap_rows()

    Enum.each(rows, fn row ->
      src_ip = Map.get(row, "src_endpoint_ip") || Map.get(row, :src_endpoint_ip)
      unique_ports = Map.get(row, "unique_ports") || Map.get(row, :unique_ports)

      if is_binary(src_ip) and is_integer(unique_ports) and unique_ports >= threshold do
        changeset =
          Ash.Changeset.for_create(NetflowPortScanFlag, :upsert, %{
            src_ip: String.trim(src_ip),
            unique_ports: unique_ports,
            window_seconds: window_seconds,
            window_end: now,
            expires_at: expires_at
          })

        _ = Ash.create(changeset, actor: actor)
      end
    end)

    :ok
  end

  defp maybe_refresh_port_scan(_settings, _actor, _now, _expires_at, _limit), do: :skip

  defp maybe_refresh_anomalies(
         %NetflowSettings{
           anomaly_enabled: true,
           anomaly_baseline_window_seconds: baseline_seconds,
           anomaly_threshold_percent: threshold_percent,
           port_scan_window_seconds: window_seconds
         },
         actor,
         now,
         expires_at,
         limit
       ) do
    baseline_token = window_seconds_to_token(baseline_seconds, fallback: "last_7d")
    window_token = window_seconds_to_token(window_seconds)

    current_q =
      ~s|in:flows time:#{window_token} stats:"sum(bytes_total) as current_bytes by dst_endpoint_port" sort:current_bytes:desc limit:#{limit}|

    baseline_q =
      ~s|in:flows time:#{baseline_token} stats:"sum(bytes_total) as baseline_bytes_total by dst_endpoint_port" sort:baseline_bytes_total:desc limit:#{limit}|

    current =
      current_q
      |> SRQLRunner.query()
      |> unwrap_rows()
      |> Enum.reduce(%{}, fn row, acc ->
        port = Map.get(row, "dst_endpoint_port") || Map.get(row, :dst_endpoint_port)
        bytes = Map.get(row, "current_bytes") || Map.get(row, :current_bytes)

        if is_integer(port) and is_integer(bytes), do: Map.put(acc, port, bytes), else: acc
      end)

    baseline_total =
      baseline_q
      |> SRQLRunner.query()
      |> unwrap_rows()
      |> Enum.reduce(%{}, fn row, acc ->
        port = Map.get(row, "dst_endpoint_port") || Map.get(row, :dst_endpoint_port)
        bytes = Map.get(row, "baseline_bytes_total") || Map.get(row, :baseline_bytes_total)

        if is_integer(port) and is_integer(bytes), do: Map.put(acc, port, bytes), else: acc
      end)

    windows_in_baseline =
      if baseline_seconds > 0 and window_seconds > 0 do
        max(div(baseline_seconds, window_seconds), 1)
      else
        max(div(604_800, max(window_seconds, 300)), 1)
      end

    Enum.each(current, fn {port, current_bytes} ->
      baseline_per_window =
        baseline_total
        |> Map.get(port, 0)
        |> div(windows_in_baseline)

      if baseline_per_window > 0 do
        # threshold_percent is expressed as "X% increase", so 300 means 4x baseline (baseline + 300%).
        trigger =
          trunc(baseline_per_window * (1.0 + threshold_percent / 100.0))

        if current_bytes > trigger do
          changeset =
            Ash.Changeset.for_create(NetflowPortAnomalyFlag, :upsert, %{
              dst_port: port,
              current_bytes: current_bytes,
              baseline_bytes: baseline_per_window,
              threshold_percent: threshold_percent,
              window_seconds: window_seconds,
              window_end: now,
              expires_at: expires_at
            })

          _ = Ash.create(changeset, actor: actor)
        end
      end
    end)

    :ok
  end

  defp maybe_refresh_anomalies(_settings, _actor, _now, _expires_at, _limit), do: :skip

  defp unwrap_rows({:ok, rows}) when is_list(rows), do: rows
  defp unwrap_rows(_), do: []

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

  defp threat_matches_for_ips(ips) when is_list(ips) do
    ips =
      ips
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&valid_ip?/1)

    if ips == [] do
      []
    else
      # We keep the query in SQL so Postgres can use the GIST index on indicator.
      sql = """
      WITH ips AS (
        SELECT unnest($1::text[]) AS ip
      )
      SELECT
        ips.ip AS ip,
        COUNT(ti.id)::int AS match_count,
        COALESCE(MAX(ti.severity), 0)::int AS max_severity,
        COALESCE(array_remove(array_agg(DISTINCT ti.source), NULL), '{}'::text[]) AS sources
      FROM ips
      LEFT JOIN platform.threat_intel_indicators ti
        ON (ti.expires_at IS NULL OR ti.expires_at > now())
       AND (ti.indicator >>= (ips.ip)::inet)
      GROUP BY ips.ip
      """

      case Ecto.Adapters.SQL.query(Repo, sql, [ips]) do
        {:ok, %Postgrex.Result{rows: rows}} ->
          Enum.map(rows, fn [ip, count, max_sev, sources] ->
            {ip, count, max_sev, sources || []}
          end)

        {:error, reason} ->
          Logger.warning("Threat intel match query failed", reason: inspect(reason))
          []
      end
    end
  end

  defp valid_ip?(ip) when is_binary(ip) do
    ip = ip |> String.trim() |> String.split("/", parts: 2) |> List.first()

    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp window_seconds_to_token(seconds, opts \\ []) when is_integer(seconds) and seconds > 0 do
    fallback = Keyword.get(opts, :fallback, @default_scan_window_token)

    cond do
      rem(seconds, 86_400) == 0 -> "last_#{div(seconds, 86_400)}d"
      rem(seconds, 3_600) == 0 -> "last_#{div(seconds, 3_600)}h"
      rem(seconds, 60) == 0 -> "last_#{div(seconds, 60)}m"
      true -> fallback
    end
  end
end
