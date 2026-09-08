defmodule ServiceRadar.Inventory.DeviceRiskIocExposure do
  @moduledoc """
  Correlates AlienVault IOC hits with attributed inbound flows onto a
  vulnerable local process.

  A hostile source IP talking to a process that matches an active package
  advisory is treated as maximum device risk and raises a detection finding
  plus a critical alert.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.Inventory.DeviceRiskReducer
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Repo

  require Logger

  @risk_source "hostile_ioc_vulnerable_service"
  @default_window_seconds 3_600
  @default_flow_limit 5_000
  @score 100
  @stop_tokens MapSet.new(~w(server client lib bin common data utils org com the))

  @comm_package_tokens %{
    "sshd" => ["openssh", "ssh"],
    "ssh" => ["openssh", "ssh"],
    "httpd" => ["apache", "httpd"],
    "apache2" => ["apache", "httpd"],
    "mysqld" => ["mysql", "mariadb"],
    "postgres" => ["postgres"],
    "redis-server" => ["redis"],
    "dockerd" => ["docker"],
    "containerd" => ["containerd"]
  }

  @doc """
  Discover current inbound IOC-to-vulnerable-service hits and apply scores,
  events, and alerts.
  """
  @spec evaluate(keyword()) :: {:ok, map()}
  def evaluate(opts \\ []) do
    hits = Keyword.get(opts, :hits) || discover_hits(opts)
    apply_hits(hits, opts)
  end

  @doc """
  Join attributed inbound hostile flows to active findings whose package
  matches the local process.
  """
  @spec correlate([map()], [map()]) :: [map()]
  def correlate(flows, findings) when is_list(flows) and is_list(findings) do
    findings_by_device = Enum.group_by(findings, & &1.device_uid)

    flows
    |> Enum.flat_map(fn flow ->
      findings_by_device
      |> Map.get(flow.device_uid, [])
      |> Enum.filter(&process_matches_package?(flow.comm, flow.cmdline, &1.package))
      |> Enum.map(&hit(flow, &1))
    end)
    |> Enum.uniq_by(&{&1.device_uid, &1.hostile_ip, &1.cve_id, &1.dst_port})
  end

  def correlate(_flows, _findings), do: []

  @doc """
  True when an attributed process name or command line refers to the
  vulnerable package.
  """
  @spec process_matches_package?(term(), term(), term()) :: boolean()
  def process_matches_package?(comm, cmdline, package) do
    package = normalize_token(package)
    comm = normalize_token(comm)
    cmdline = normalize_token(cmdline)

    cond do
      is_nil(package) ->
        false

      comm &&
          (comm == package or String.contains?(package, comm) or String.contains?(comm, package)) ->
        true

      comm && alias_overlap?(comm, package) ->
        true

      token_overlap?(comm, package) ->
        true

      cmdline && String.contains?(cmdline, package) ->
        true

      true ->
        false
    end
  end

  defp discover_hits(opts) do
    flows = query_flows(opts)
    device_uids = flows |> Enum.map(& &1.device_uid) |> Enum.uniq()
    findings = query_findings(device_uids, opts)
    correlate(flows, findings)
  end

  defp apply_hits(hits, opts) when is_list(hits) do
    now = DateTime.utc_now()
    grouped = Enum.group_by(hits, & &1.device_uid)
    active_uids = MapSet.new(Map.keys(grouped))

    Enum.each(grouped, fn {device_uid, device_hits} ->
      upsert_max_score(device_uid, device_hits, now, opts)
    end)

    resolved = resolve_stale(active_uids, now, opts)
    {events, alerts} = emit_new(hits, opts)

    {:ok,
     %{
       devices: MapSet.size(active_uids),
       hits: length(hits),
       events: events,
       alerts: alerts,
       resolved: resolved
     }}
  end

  defp hit(flow, finding) do
    %{
      device_uid: flow.device_uid,
      agent_id: flow.agent_id,
      hostile_ip: flow.hostile_ip,
      dst_ip: flow.dst_ip,
      dst_port: flow.dst_port,
      comm: flow.comm,
      cmdline: flow.cmdline,
      observed_at: flow.observed_at,
      ioc_sources: flow.ioc_sources,
      ioc_severity: flow.ioc_severity,
      cve_id: finding.cve_id,
      package: finding.package,
      kev: finding.kev,
      cvss: finding.cvss
    }
  end

  defp upsert_max_score(device_uid, hits, now, opts) do
    [worst | _] =
      Enum.sort_by(hits, fn hit ->
        {-if(hit.kev, do: 1, else: 0), -(hit.cvss || 0), hit.cve_id || ""}
      end)

    upsert_contribution =
      Keyword.get(opts, :upsert_contribution, &DeviceRiskReducer.upsert_contribution/2)

    upsert_contribution.(
      %{
        device_uid: device_uid,
        source: @risk_source,
        source_ref: device_uid,
        score: @score,
        reason: score_reason(worst),
        active: true,
        occurred_at: worst.observed_at || now,
        resolved_at: nil,
        metadata: %{
          "source" => @risk_source,
          "cve" => worst.cve_id,
          "package" => worst.package,
          "hostile_ip" => worst.hostile_ip,
          "dst_port" => worst.dst_port,
          "comm" => worst.comm,
          "kev" => worst.kev,
          "ioc_sources" => worst.ioc_sources,
          "hit_count" => length(hits)
        }
      },
      opts
    )
  end

  defp score_reason(hit) do
    [
      hit.cve_id,
      hit.package || hit.comm,
      "hostile #{hit.hostile_ip}",
      hit.dst_port && "port #{hit.dst_port}",
      "AlienVault IOC"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp resolve_stale(active_uids, now, opts) do
    query_active = Keyword.get(opts, :query_active_contribution_uids, &active_contribution_uids/0)

    stale = Enum.reject(query_active.(), &MapSet.member?(active_uids, &1))

    upsert_contribution =
      Keyword.get(opts, :upsert_contribution, &DeviceRiskReducer.upsert_contribution/2)

    Enum.each(stale, fn device_uid ->
      upsert_contribution.(
        %{
          device_uid: device_uid,
          source: @risk_source,
          source_ref: device_uid,
          score: 0,
          reason: "no inbound IOC hit on a vulnerable service",
          active: false,
          occurred_at: now,
          resolved_at: now,
          metadata: %{"source" => @risk_source}
        },
        opts
      )
    end)

    length(stale)
  end

  defp emit_new(hits, opts) do
    Enum.reduce(hits, {0, 0}, fn hit, {events, alerts} ->
      source_id = alert_source_id(hit)
      open_alert? = Keyword.get(opts, :open_alert?, &open_alert?/1)

      if open_alert?.(source_id) do
        {events, alerts}
      else
        event_ok? = emit_event(hit, opts)
        alert_ok? = create_alert(hit, source_id, opts)
        {events + if(event_ok?, do: 1, else: 0), alerts + if(alert_ok?, do: 1, else: 0)}
      end
    end)
  end

  defp emit_event(hit, opts) do
    emit = Keyword.get(opts, :emit_event, &default_emit_event/1)

    case emit.(event_payload(hit)) do
      :ok ->
        true

      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("Hostile IOC exposure event failed", reason: inspect(reason))
        false
    end
  end

  defp create_alert(hit, source_id, opts) do
    create = Keyword.get(opts, :create_alert, &default_create_alert/1)

    case create.(alert_attrs(hit, source_id)) do
      {:ok, _} ->
        true

      :ok ->
        true

      {:error, reason} ->
        Logger.warning("Hostile IOC exposure alert failed", reason: inspect(reason))
        false
    end
  end

  defp event_payload(hit) do
    %{
      "event_id" => alert_source_id(hit),
      "signal_type" => "inventory",
      "event_type" => "hostile_ioc_vulnerable_service",
      "timestamp" =>
        hit.observed_at
        |> Kernel.||(DateTime.utc_now())
        |> DateTime.to_iso8601(),
      "severity" => "Critical",
      "severity_id" => 5,
      "device_uid" => hit.device_uid,
      "agent_id" => hit.agent_id,
      "cve" => hit.cve_id,
      "cve_id" => hit.cve_id,
      "package" => %{"name" => hit.package},
      "hostile_ip" => hit.hostile_ip,
      "dst_ip" => hit.dst_ip,
      "dst_port" => hit.dst_port,
      "comm" => hit.comm,
      "kev" => hit.kev,
      "ioc_sources" => hit.ioc_sources,
      "provider" => "device_risk_assessment",
      "source" => @risk_source,
      "status" => "open",
      "message" =>
        "Hostile IP #{hit.hostile_ip} connected to #{hit.package || hit.comm || "a vulnerable service"}" <>
          if(hit.cve_id, do: " (#{hit.cve_id})", else: "")
    }
  end

  defp alert_attrs(hit, source_id) do
    %{
      title: "Hostile IP on vulnerable service: #{hit.package || hit.comm || hit.cve_id}",
      description: event_payload(hit)["message"],
      severity: :critical,
      source_type: :event,
      source_id: source_id,
      device_uid: hit.device_uid,
      agent_uid: hit.agent_id,
      event_time: hit.observed_at,
      metadata: %{
        "source" => @risk_source,
        "cve" => hit.cve_id,
        "package" => hit.package,
        "hostile_ip" => hit.hostile_ip,
        "dst_port" => hit.dst_port,
        "comm" => hit.comm,
        "ioc_sources" => hit.ioc_sources
      }
    }
  end

  defp alert_source_id(hit) do
    "hostile-ioc-vuln:#{hit.device_uid}:#{hit.hostile_ip}:#{hit.cve_id || "unknown"}"
  end

  defp default_emit_event(payload) do
    message = %{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.inventory.hostile_ioc_vulnerable_service",
        received_at: DateTime.utc_now()
      }
    }

    AnalyticsSignals.process_batch([message])
  end

  defp default_create_alert(attrs) do
    actor = SystemActor.system(:device_risk_ioc_exposure)

    Alert
    |> Ash.Changeset.for_create(:trigger, attrs, actor: actor)
    |> Ash.create()
  end

  defp open_alert?(source_id) do
    Repo.exists?(
      from(a in "alerts",
        where:
          a.source_id == ^source_id and
            a.status in ["pending", "acknowledged", "escalated"],
        limit: 1
      ),
      prefix: "platform"
    )
  end

  defp active_contribution_uids do
    Repo.all(
      from(c in "device_risk_contributions",
        where: c.source == ^@risk_source and c.active == true,
        distinct: true,
        select: c.device_uid
      ),
      prefix: "platform"
    )
  end

  defp query_flows(opts) do
    query_fn = Keyword.get(opts, :query_flows)

    if is_function(query_fn, 1) do
      query_fn.(opts)
    else
      window_seconds =
        opts
        |> Keyword.get(:window_seconds, @default_window_seconds)
        |> max(60)

      limit =
        opts
        |> Keyword.get(:flow_limit, @default_flow_limit)
        |> min(20_000)
        |> max(1)

      sql = """
      SELECT
        COALESCE(a.device_uid, di.device_id) AS device_uid,
        f.ocsf_payload->>'agent_id' AS agent_id,
        lower(regexp_replace(coalesce(f.src_endpoint_ip, ''), '^::ffff:', '', 'i')) AS hostile_ip,
        lower(regexp_replace(coalesce(f.dst_endpoint_ip, ''), '^::ffff:', '', 'i')) AS dst_ip,
        f.dst_endpoint_port AS dst_port,
        f.ocsf_payload->'attribution'->>'comm' AS comm,
        COALESCE(
          f.ocsf_payload->'attribution'->>'redacted_cmdline',
          f.ocsf_payload->'attribution'->>'cmdline'
        ) AS cmdline,
        f.time AS observed_at,
        t.sources AS ioc_sources,
        t.max_severity AS ioc_severity
      FROM platform.ocsf_network_activity AS f
      JOIN platform.ip_threat_intel_cache AS t
        ON t.matched = true
       AND t.expires_at > now()
       AND lower(regexp_replace(coalesce(t.ip, ''), '^::ffff:', '', 'i'))
         = lower(regexp_replace(coalesce(f.src_endpoint_ip, ''), '^::ffff:', '', 'i'))
      LEFT JOIN platform.ocsf_agents AS a
        ON a.uid = f.ocsf_payload->>'agent_id'
      LEFT JOIN LATERAL (
        SELECT di.device_id
        FROM platform.device_identifiers AS di
        WHERE di.identifier_type = 'ip'
          AND lower(di.identifier_value)
            = lower(regexp_replace(coalesce(f.dst_endpoint_ip, ''), '^::ffff:', '', 'i'))
        LIMIT 1
      ) AS di ON a.device_uid IS NULL
      WHERE f.time > now() - make_interval(secs => $1)
        AND f.ocsf_payload->>'event_type' = 'attributed_flow'
        AND COALESCE(a.device_uid, di.device_id) IS NOT NULL
      ORDER BY f.time DESC
      LIMIT $2
      """

      case SQL.query(Repo, sql, [window_seconds, limit]) do
        {:ok, %{columns: columns, rows: rows}} ->
          Enum.map(rows, &flow_row(columns, &1))

        {:error, reason} ->
          raise "hostile IOC flow query failed: #{inspect(reason)}"
      end
    end
  end

  defp query_findings([], _opts), do: []

  defp query_findings(device_uids, opts) do
    query_fn = Keyword.get(opts, :query_findings)

    if is_function(query_fn, 2) do
      query_fn.(device_uids, opts)
    else
      Repo.all(
        from(a in "endpoint_vulnerability_assessments",
          where:
            a.device_uid in ^device_uids and a.status == "active" and
              a.assessment == "confirmed" and a.disposition == "affected",
          select: %{
            device_uid: a.device_uid,
            cve_id: a.cve_id,
            kev: a.kev,
            cvss: a.cvss_score,
            package: a.package_name
          }
        ),
        prefix: "platform"
      )
    end
  end

  defp flow_row(columns, values) do
    row =
      columns
      |> Enum.zip(values)
      |> Map.new(fn {column, value} -> {column, value} end)

    %{
      device_uid: row["device_uid"],
      agent_id: row["agent_id"],
      hostile_ip: row["hostile_ip"],
      dst_ip: row["dst_ip"],
      dst_port: row["dst_port"],
      comm: row["comm"],
      cmdline: row["cmdline"],
      observed_at: row["observed_at"],
      ioc_sources: List.wrap(row["ioc_sources"]),
      ioc_severity: row["ioc_severity"]
    }
  end

  defp alias_overlap?(comm, package) do
    @comm_package_tokens
    |> Map.get(comm, [])
    |> Enum.any?(&String.contains?(package, &1))
  end

  defp token_overlap?(nil, _package), do: false

  defp token_overlap?(comm, package) do
    comm_tokens = tokens(comm)
    package_tokens = tokens(package)

    comm_tokens != [] and package_tokens != [] and
      not MapSet.disjoint?(MapSet.new(comm_tokens), MapSet.new(package_tokens))
  end

  defp tokens(value) do
    value
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3 or MapSet.member?(@stop_tokens, &1)))
  end

  defp normalize_token(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "" -> nil
      token -> token
    end
  end

  defp normalize_token(_value), do: nil
end
