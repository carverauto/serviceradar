defmodule ServiceRadar.Observability.NetflowSecurityRefreshWorker do
  @moduledoc """
  Refreshes optional NetFlow security intelligence caches.

  This worker is intentionally SRQL-driven for metric discovery/aggregation.
  It writes to bounded cache tables for cheap UI lookups.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

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

  defp maybe_refresh_threat(
         %NetflowSettings{threat_intel_enabled: true} = settings,
         actor,
         now,
         expires_at,
         limit
       ) do
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

    current = srql_query_to_int_map(current_q, "dst_endpoint_port", "current_bytes")

    baseline_total =
      srql_query_to_int_map(baseline_q, "dst_endpoint_port", "baseline_bytes_total")

    windows = windows_in_baseline(baseline_seconds, window_seconds)

    ctx = %{
      threshold_percent: threshold_percent,
      window_seconds: window_seconds,
      now: now,
      expires_at: expires_at,
      actor: actor
    }

    Enum.each(current, fn {port, current_bytes} ->
      baseline_bytes_total = Map.get(baseline_total, port, 0)
      maybe_upsert_port_anomaly(port, current_bytes, baseline_bytes_total, windows, ctx)
    end)

    :ok
  end

  defp maybe_refresh_anomalies(_settings, _actor, _now, _expires_at, _limit), do: :skip

  defp unwrap_rows({:ok, rows}) when is_list(rows), do: rows
  defp unwrap_rows(_), do: []

  defp srql_query_to_int_map(query, key_field, value_field)
       when is_binary(query) and is_binary(key_field) and is_binary(value_field) do
    # SRQL result rows are usually string-keyed, but may come through with atom keys
    # depending on the caller. Never call String.to_existing_atom/1 on arbitrary field
    # names because that can crash when atoms haven't been created.
    key_atom = maybe_existing_atom(key_field)
    value_atom = maybe_existing_atom(value_field)

    query
    |> SRQLRunner.query()
    |> unwrap_rows()
    |> Enum.reduce(%{}, fn row, acc ->
      key = Map.get(row, key_field) || (key_atom && Map.get(row, key_atom))
      value = Map.get(row, value_field) || (value_atom && Map.get(row, value_atom))

      if is_integer(key) and is_integer(value), do: Map.put(acc, key, value), else: acc
    end)
  end

  defp maybe_existing_atom(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> nil
  end

  defp windows_in_baseline(baseline_seconds, window_seconds) do
    if baseline_seconds > 0 and window_seconds > 0 do
      max(div(baseline_seconds, window_seconds), 1)
    else
      max(div(604_800, max(window_seconds, 300)), 1)
    end
  end

  defp maybe_upsert_port_anomaly(
         port,
         current_bytes,
         baseline_bytes_total,
         windows_in_baseline,
         %{
           threshold_percent: threshold_percent,
           window_seconds: window_seconds,
           now: now,
           expires_at: expires_at,
           actor: actor
         }
       )
       when is_integer(port) and is_integer(current_bytes) and is_integer(baseline_bytes_total) do
    baseline_per_window = div(max(baseline_bytes_total, 0), max(windows_in_baseline, 1))

    # threshold_percent is expressed as "X% increase", so 300 means 4x baseline (baseline + 300%).
    trigger = calc_anomaly_trigger(baseline_per_window, threshold_percent)

    if baseline_per_window > 0 and current_bytes > trigger do
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

    :ok
  end

  defp maybe_upsert_port_anomaly(_port, _current, _baseline_total, _windows, _ctx), do: :skip

  defp calc_anomaly_trigger(baseline_per_window, threshold_percent)
       when is_integer(baseline_per_window) and is_number(threshold_percent) do
    trunc(baseline_per_window * (1.0 + threshold_percent / 100.0))
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

  defp threat_matches_for_ips(ips) when is_list(ips) do
    ips =
      ips
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&valid_ip?/1)

    if ips == [], do: [], else: run_threat_match_query(ips)
  end

  defp run_threat_match_query(ips) when is_list(ips) do
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
        Enum.map(rows, &threat_match_row/1)

      {:error, reason} ->
        Logger.warning("Threat intel match query failed", reason: inspect(reason))
        []
    end
  end

  defp threat_match_row([ip, count, max_sev, sources]) do
    {ip, count, max_sev, sources || []}
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
