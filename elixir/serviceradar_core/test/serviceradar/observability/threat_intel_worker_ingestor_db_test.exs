defmodule ServiceRadar.Observability.ThreatIntelWorkerIngestorDBTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.NetflowSecurityRefreshWorker
  alias ServiceRadar.Observability.ThreatIntel.Page
  alias ServiceRadar.Observability.ThreatIntelPluginIngestor
  alias ServiceRadar.Observability.ThreatIntelRetrohuntWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @cursor_plugin_id "alienvault-otx-cursor-test"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    reset_threat_intel_tables()
    :ok
  end

  test "plugin ingest upserts OTX indicators and preserves unsupported counts" do
    actor = SystemActor.system(:otx_plugin_ingestor_db_test)
    observed_at = ~U[2026-04-28 00:00:00Z]

    payload = %{
      "status" => "ok",
      "summary" => "OTX pulses imported",
      "threat_intel" => %{
        "provider" => "alienvault_otx",
        "source" => "alienvault_otx",
        "collection_id" => "otx:pulses:subscribed",
        "counts" => %{
          "objects" => 1,
          "indicators" => 1,
          "skipped" => 2,
          "skipped_by_type" => %{"domain" => 1, "url" => 1},
          "total" => 3
        },
        "indicators" => [
          %{
            "indicator" => "192.0.2.45",
            "label" => "Known C2",
            "severity_id" => 4,
            "confidence" => 88,
            "source_object_id" => "pulse-otx-1",
            "source_context" => "otx-user"
          },
          %{"indicator" => "example.invalid", "type" => "domain"},
          %{"indicator" => "https://example.invalid/path", "type" => "url"}
        ]
      }
    }

    status = %{"plugin_id" => "alienvault-otx-threat-intel", "agent_id" => "edge-1"}

    :ok =
      ThreatIntelPluginIngestor.ingest(payload, status, actor: actor, observed_at: observed_at)

    :ok =
      ThreatIntelPluginIngestor.ingest(payload, status, actor: actor, observed_at: observed_at)

    assert [[1]] =
             query!(
               "SELECT COUNT(*)::int FROM platform.threat_intel_indicators WHERE source = $1",
               ["alienvault_otx"]
             ).rows

    assert [[1]] =
             query!(
               "SELECT COUNT(*)::int FROM platform.threat_intel_source_objects WHERE source = $1",
               ["alienvault_otx"]
             ).rows

    assert [[2, %{"skipped_by_type" => %{"domain" => 1, "url" => 1}}]] =
             query!(
               """
               SELECT skipped_count, metadata
               FROM platform.threat_intel_sync_statuses
               WHERE source = $1 AND collection_id = $2
               """,
               ["alienvault_otx", "otx:pulses:subscribed"]
             ).rows
  end

  test "edge plugin ingest persists cursor from assignment id in status labels" do
    actor = SystemActor.system(:otx_plugin_cursor_test)
    observed_at = ~U[2026-04-28 00:00:00Z]
    assignment_id = seed_plugin_assignment(%{"page" => 20, "limit" => 100})

    page = %Page{
      provider: "alienvault_otx",
      source: "alienvault_otx",
      collection_id: "otx:export",
      cursor: %{
        "next" => "https://otx.alienvault.com/api/v1/indicators/export?limit=100&page=25",
        "next_page" => "25",
        "complete" => "false"
      },
      counts: %{"total" => 494_254, "indicators" => 1, "skipped" => 0},
      indicators: [
        %{
          "indicator" => "192.0.2.46",
          "label" => "OTX cursor regression",
          "source_object_id" => "otx-export-cursor-1"
        }
      ]
    }

    payload = %{"status" => "ok", "summary" => "OTX export page imported"}

    status = %{
      "plugin_id" => @cursor_plugin_id,
      "agent_id" => "edge-1",
      "labels" => %{"assignment_id" => assignment_id}
    }

    :ok =
      ThreatIntelPluginIngestor.ingest_page(page, payload, status,
        actor: actor,
        observed_at: observed_at
      )

    assert [[25, false, "https://otx.alienvault.com/api/v1/indicators/export?limit=100&page=25"]] =
             query!(
               """
               SELECT
                 (params->>'page')::int,
                 (params->>'cursor_complete')::boolean,
                 params->>'cursor_next'
               FROM platform.plugin_assignments
               WHERE id = ($1::text)::uuid
               """,
               [assignment_id]
             ).rows
  end

  test "netflow security refresh caches OTX CIDR matches for recent flow IPs" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    enable_threat_intel_settings()
    seed_indicator("alienvault_otx", "198.51.100.0/24", 5, now)
    seed_ocsf_flow(now, "198.51.100.23", "203.0.113.10")

    assert :ok = NetflowSecurityRefreshWorker.perform(%Oban.Job{args: %{}})

    assert [[true, 1, 5, ["alienvault_otx"]]] =
             query!(
               """
               SELECT matched, match_count, max_severity, sources
               FROM platform.ip_threat_intel_cache
               WHERE ip = $1
               """,
               ["198.51.100.23"]
             ).rows
  end

  test "manual OTX retrohunt deduplicates netflow findings across repeated runs" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    flow_time = DateTime.add(now, -60, :second)

    indicator_id = seed_indicator("alienvault_otx", "203.0.113.0/24", 4, now)
    seed_ocsf_flow(flow_time, "10.0.0.8", "203.0.113.77")
    seed_ocsf_flow(flow_time, "10.0.0.9", "203.0.113.77")
    seed_sync_status_with_unsupported_count(now, %{"domain" => 2, "url" => 1})

    args = %{
      "source" => "alienvault_otx",
      "window_seconds" => 3_600,
      "max_indicators" => 100,
      "triggered_by" => "manual-test"
    }

    assert :ok = ThreatIntelRetrohuntWorker.perform(%Oban.Job{args: args})
    assert :ok = ThreatIntelRetrohuntWorker.perform(%Oban.Job{args: args})

    assert [[1, ^indicator_id, 2]] =
             query!(
               """
               SELECT COUNT(*)::int, MIN(indicator_id::text), MAX(evidence_count)::int
               FROM platform.otx_retrohunt_findings
               WHERE source = $1 AND observed_ip = ($2::text)::inet
               """,
               ["alienvault_otx", "203.0.113.77"]
             ).rows

    assert [["ok", 1, 3]] =
             query!(
               """
               SELECT status, findings_count, unsupported_count
               FROM platform.otx_retrohunt_runs
               WHERE source = $1
               ORDER BY started_at DESC
               LIMIT 1
               """,
               ["alienvault_otx"]
             ).rows
  end

  defp reset_threat_intel_tables do
    Enum.each(
      [
        "platform.otx_retrohunt_findings",
        "platform.otx_retrohunt_runs",
        "platform.ip_threat_intel_cache",
        "platform.threat_intel_sync_statuses",
        "platform.threat_intel_source_objects",
        "platform.threat_intel_indicators",
        "platform.ocsf_network_activity"
      ],
      fn table -> query!("DELETE FROM #{table}", []) end
    )

    query!(
      """
      UPDATE platform.netflow_settings
      SET threat_intel_enabled = false,
          anomaly_enabled = false,
          port_scan_enabled = false,
          updated_at = now()
      """,
      []
    )

    query!(
      """
      DELETE FROM platform.plugin_assignments
      WHERE plugin_package_id IN (
        SELECT id FROM platform.plugin_packages WHERE plugin_id = $1
      )
      """,
      [@cursor_plugin_id]
    )

    query!("DELETE FROM platform.plugin_packages WHERE plugin_id = $1", [@cursor_plugin_id])
    query!("DELETE FROM platform.plugins WHERE plugin_id = $1", [@cursor_plugin_id])
  end

  defp enable_threat_intel_settings do
    query!(
      """
      UPDATE platform.netflow_settings
      SET threat_intel_enabled = true,
          threat_intel_match_window_seconds = 3600,
          anomaly_enabled = false,
          port_scan_enabled = false,
          updated_at = now()
      """,
      []
    )
  end

  defp seed_indicator(source, cidr, severity, now) do
    %Postgrex.Result{rows: [[id]]} =
      query!(
        """
        INSERT INTO platform.threat_intel_indicators (
          indicator,
          indicator_type,
          source,
          label,
          severity,
          confidence,
          first_seen_at,
          last_seen_at,
          inserted_at,
          updated_at
        )
        VALUES (($1::text)::cidr, 'cidr', $2, 'OTX test indicator', $3, 90, $4, $4, $4, $4)
        RETURNING id::text
        """,
        [cidr, source, severity, now]
      )

    id
  end

  defp seed_ocsf_flow(time, src_ip, dst_ip) do
    query!(
      """
      INSERT INTO platform.ocsf_network_activity (
        time,
        src_endpoint_ip,
        src_endpoint_port,
        dst_endpoint_ip,
        dst_endpoint_port,
        protocol_num,
        protocol_name,
        bytes_total,
        packets_total,
        ocsf_payload
      )
      VALUES ($1, $2, 443, $3, 51515, 6, 'tcp', 2048, 8, '{}'::jsonb)
      """,
      [time, src_ip, dst_ip]
    )
  end

  defp seed_sync_status_with_unsupported_count(now, skipped_by_type) do
    query!(
      """
      INSERT INTO platform.threat_intel_sync_statuses (
        provider,
        source,
        collection_id,
        execution_mode,
        last_status,
        last_attempt_at,
        last_success_at,
        skipped_count,
        metadata,
        inserted_at,
        updated_at
      )
      VALUES (
        'alienvault_otx',
        'alienvault_otx',
        'otx:pulses:subscribed',
        'core_worker',
        'ok',
        $1,
        $1,
        3,
        jsonb_build_object('skipped_by_type', ($2::text)::jsonb),
        $1,
        $1
      )
      """,
      [now, Jason.encode!(skipped_by_type)]
    )
  end

  defp seed_plugin_assignment(params) do
    package_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    query!(
      """
      INSERT INTO platform.plugins (
        plugin_id,
        name,
        description,
        inserted_at,
        updated_at
      )
      VALUES ($1, 'AlienVault OTX cursor test', 'OTX cursor persistence test plugin', $2, $2)
      """,
      [@cursor_plugin_id, now]
    )

    query!(
      """
      INSERT INTO platform.plugin_packages (
        id,
        plugin_id,
        name,
        version,
        description,
        entrypoint,
        runtime,
        outputs,
        manifest,
        config_schema,
        display_contract,
        signature,
        source_type,
        status,
        approved_capabilities,
        approved_permissions,
        approved_resources,
        approved_by,
        approved_at,
        inserted_at,
        updated_at
      )
      VALUES (
        ($1::text)::uuid,
        $2,
        'AlienVault OTX cursor test',
        '0.1.0',
        'OTX cursor persistence test plugin',
        'main.wasm',
        'wasi-preview1',
        'serviceradar.plugin_result.v1',
        '{}'::jsonb,
        '{}'::jsonb,
        '{}'::jsonb,
        '{}'::jsonb,
        'upload',
        'approved',
        '{}',
        '{}'::jsonb,
        '{}'::jsonb,
        'test',
        $3,
        $3,
        $3
      )
      """,
      [package_id, @cursor_plugin_id, now]
    )

    query!(
      """
      INSERT INTO platform.plugin_assignments (
        id,
        agent_uid,
        plugin_package_id,
        source,
        enabled,
        interval_seconds,
        timeout_seconds,
        params,
        permissions_override,
        resources_override,
        inserted_at,
        updated_at
      )
      VALUES (
        ($1::text)::uuid,
        'edge-1',
        ($2::text)::uuid,
        'manual',
        true,
        21600,
        7200,
        ($3::text)::jsonb,
        '{}'::jsonb,
        '{}'::jsonb,
        $4,
        $4
      )
      """,
      [assignment_id, package_id, Jason.encode!(params), now]
    )

    assignment_id
  end

  defp query!(sql, params) do
    SQL.query!(Repo, sql, params, timeout: 120_000)
  end
end
