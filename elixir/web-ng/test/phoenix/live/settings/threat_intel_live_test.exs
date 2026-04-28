defmodule ServiceRadarWebNGWeb.Settings.ThreatIntelLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  @plugin_id "alienvault-otx-threat-intel"

  setup :register_and_log_in_admin_user

  setup do
    reset_threat_intel_rows()
    :ok
  end

  test "viewer is blocked from threat intel settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/threat-intel")
    assert to == ~p"/settings/profile"
  end

  test "saves and clears OTX settings without echoing the API key", %{conn: conn, scope: scope} do
    {:ok, lv, html} = live(conn, ~p"/settings/networks/threat-intel")

    assert html =~ "Threat Intel"
    refute html =~ "otx-liveview-secret"

    lv
    |> form("#otx-settings-form", %{
      "settings" => %{
        "otx_enabled" => "true",
        "otx_execution_mode" => "core_worker",
        "otx_base_url" => "https://otx.alienvault.com",
        "otx_api_key" => "otx-liveview-secret",
        "otx_sync_interval_seconds" => "900",
        "otx_page_size" => "75",
        "otx_timeout_ms" => "15000",
        "otx_max_indicators" => "2500",
        "otx_retrohunt_window_seconds" => "86400",
        "threat_intel_match_window_seconds" => "1800",
        "otx_raw_payload_archive_enabled" => "true"
      }
    })
    |> render_submit()

    html = render(lv)
    assert html =~ "Saved OTX settings"
    assert html =~ "key saved"
    refute html =~ "otx-liveview-secret"

    assert %NetflowSettings{
             otx_enabled: true,
             otx_execution_mode: "core_worker",
             otx_api_key: "otx-liveview-secret",
             otx_api_key_present: true,
             otx_raw_payload_archive_enabled: true
           } = load_settings!(scope)

    lv
    |> form("#otx-settings-form", %{
      "settings" => %{
        "otx_enabled" => "true",
        "otx_execution_mode" => "core_worker",
        "otx_base_url" => "https://otx.alienvault.com",
        "clear_otx_api_key" => "true",
        "otx_sync_interval_seconds" => "900",
        "otx_page_size" => "75",
        "otx_timeout_ms" => "15000",
        "otx_max_indicators" => "2500",
        "otx_retrohunt_window_seconds" => "86400",
        "threat_intel_match_window_seconds" => "1800"
      }
    })
    |> render_submit()

    refute render(lv) =~ "key saved"
    refute load_settings!(scope).otx_api_key_present
  end

  test "renders OTX findings, imported indicators, source objects, and sync status", %{conn: conn} do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    indicator_id = seed_indicator("198.51.100.0/24", now)
    seed_sync_status(now)
    seed_current_finding(now)
    seed_retrohunt_run_and_finding(indicator_id, now)
    seed_source_object(now)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/threat-intel")

    assert html =~ "edge-otx-agent"
    assert html =~ "domain: 2"
    assert html =~ "198.51.100.23"
    assert html =~ "203.0.113.77"
    assert html =~ "OTX test indicator"
    assert html =~ "pulse-liveview-1"
  end

  test "saves an edge plugin assignment without rendering the raw secret", %{
    conn: conn,
    scope: scope
  } do
    package = seed_approved_package()
    agent = seed_agent()

    {:ok, lv, html} = live(conn, ~p"/settings/networks/threat-intel")

    assert html =~ "approved"
    assert html =~ agent.uid

    lv
    |> form("#otx-assignment-form", %{
      "assignment" => %{
        "agent_uid" => agent.uid,
        "enabled" => "true",
        "interval_seconds" => "600",
        "timeout_seconds" => "25",
        "base_url" => "https://otx.alienvault.com",
        "api_key_secret_ref" => "edge-liveview-secret",
        "limit" => "25",
        "page" => "1",
        "timeout_ms" => "12000",
        "max_indicators" => "500"
      }
    })
    |> render_submit()

    html = render(lv)
    assert html =~ "Assignment saved"
    assert html =~ agent.uid
    refute html =~ "edge-liveview-secret"

    assignment =
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(agent_uid == ^agent.uid and plugin_package_id == ^package.id)
      |> Ash.read_one!(scope: scope)

    assert %PluginAssignment{
             interval_seconds: 600,
             timeout_seconds: 25,
             enabled: true
           } = assignment

    assert assignment.params["base_url"] == "https://otx.alienvault.com"
    assert assignment.params["api_key_secret_ref"] =~ "secretref:api_key"

    %Postgrex.Result{rows: [[raw_params]]} =
      query!(
        "SELECT params::text FROM platform.plugin_assignments WHERE id = ($1::text)::uuid",
        [assignment.id]
      )

    refute raw_params =~ "edge-liveview-secret"
  end

  test "manual sync and retrohunt buttons report enqueue outcome", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/threat-intel")

    sync_html =
      lv
      |> element("button", "Sync Now")
      |> render_click()

    assert sync_html =~ "OTX sync queued" or sync_html =~ "Job scheduler is unavailable"

    retrohunt_html =
      lv
      |> element("button", "Retrohunt Now")
      |> render_click()

    assert retrohunt_html =~ "OTX retrohunt queued" or
             retrohunt_html =~ "Job scheduler is unavailable"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp reset_threat_intel_rows do
    Enum.each(
      [
        "platform.otx_retrohunt_findings",
        "platform.otx_retrohunt_runs",
        "platform.ip_threat_intel_cache",
        "platform.threat_intel_sync_statuses",
        "platform.threat_intel_source_objects",
        "platform.threat_intel_indicators",
        "platform.plugin_assignments",
        "platform.plugin_packages"
      ],
      fn table -> query!("DELETE FROM #{table}", []) end
    )

    query!("DELETE FROM platform.plugins WHERE plugin_id = $1", [@plugin_id])

    query!(
      """
      UPDATE platform.netflow_settings
      SET otx_enabled = false,
          otx_execution_mode = 'edge_plugin',
          encrypted_otx_api_key = NULL,
          otx_raw_payload_archive_enabled = false,
          updated_at = now()
      """,
      []
    )
  end

  defp load_settings!(scope) do
    NetflowSettings
    |> Ash.Query.for_read(:get_singleton)
    |> Ash.read_one!(scope: scope)
  end

  defp seed_indicator(cidr, now) do
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
        VALUES (($1::text)::cidr, 'cidr', 'alienvault_otx', 'OTX test indicator', 5, 90, $2, $2, $2, $2)
        RETURNING id::text
        """,
        [cidr, now]
      )

    id
  end

  defp seed_sync_status(now) do
    query!(
      """
      INSERT INTO platform.threat_intel_sync_statuses (
        provider,
        source,
        collection_id,
        agent_id,
        gateway_id,
        plugin_id,
        execution_mode,
        last_status,
        last_attempt_at,
        last_success_at,
        objects_count,
        indicators_count,
        skipped_count,
        total_count,
        metadata,
        inserted_at,
        updated_at
      )
      VALUES (
        'alienvault_otx',
        'alienvault_otx',
        'otx:pulses:subscribed',
        'edge-otx-agent',
        'edge-otx-gateway',
        $1,
        'edge_plugin',
        'ok',
        $2,
        $2,
        1,
        3,
        2,
        5,
        jsonb_build_object('skipped_by_type', jsonb_build_object('domain', 2)),
        $2,
        $2
      )
      """,
      [@plugin_id, now]
    )
  end

  defp seed_current_finding(now) do
    query!(
      """
      INSERT INTO platform.ip_threat_intel_cache (
        ip,
        matched,
        match_count,
        max_severity,
        sources,
        looked_up_at,
        expires_at,
        inserted_at,
        updated_at
      )
      VALUES ($1, true, 2, 5, $2, $3, $4, $3, $3)
      """,
      ["198.51.100.23", ["alienvault_otx"], now, DateTime.add(now, 3600, :second)]
    )
  end

  defp seed_retrohunt_run_and_finding(indicator_id, now) do
    window_start = DateTime.add(now, -3600, :second)

    %Postgrex.Result{rows: [[run_id]]} =
      query!(
        """
        INSERT INTO platform.otx_retrohunt_runs (
          source,
          triggered_by,
          status,
          window_start,
          window_end,
          started_at,
          finished_at,
          indicators_evaluated,
          findings_count,
          unsupported_count,
          inserted_at,
          updated_at
        )
        VALUES ('alienvault_otx', 'manual', 'ok', $1, $2, $1, $2, 1, 1, 2, $2, $2)
        RETURNING id::text
        """,
        [window_start, now]
      )

    query!(
      """
      INSERT INTO platform.otx_retrohunt_findings (
        run_id,
        indicator_id,
        source,
        indicator,
        indicator_type,
        label,
        severity,
        confidence,
        observed_ip,
        direction,
        first_seen_at,
        last_seen_at,
        evidence_count,
        bytes_total,
        packets_total,
        inserted_at,
        updated_at
      )
      VALUES (
        ($1::text)::uuid,
        ($2::text)::uuid,
        'alienvault_otx',
        ($3::text)::cidr,
        'cidr',
        'OTX test indicator',
        5,
        90,
        ($4::text)::inet,
        'destination',
        $5,
        $6,
        4,
        4096,
        12,
        $6,
        $6
      )
      """,
      [run_id, indicator_id, "203.0.113.0/24", "203.0.113.77", window_start, now]
    )
  end

  defp seed_source_object(now) do
    query!(
      """
      INSERT INTO platform.threat_intel_source_objects (
        provider,
        source,
        collection_id,
        object_id,
        object_type,
        object_version,
        modified_at,
        metadata,
        inserted_at,
        updated_at
      )
      VALUES (
        'alienvault_otx',
        'alienvault_otx',
        'otx:pulses:subscribed',
        'pulse-liveview-1',
        'otx-pulse',
        $1,
        $2,
        jsonb_build_object('label', 'OTX test pulse'),
        $2,
        $2
      )
      """,
      [DateTime.to_iso8601(now), now]
    )
  end

  defp seed_approved_package do
    version = "0.1.#{System.unique_integer([:positive])}"
    package_id = Ecto.UUID.generate()
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    manifest = otx_manifest(version)
    config_schema = otx_config_schema()

    query!(
      """
      INSERT INTO platform.plugins (
        plugin_id,
        name,
        description,
        inserted_at,
        updated_at
      )
      VALUES ($1, 'AlienVault OTX', 'OTX test plugin', $2, $2)
      ON CONFLICT (plugin_id) DO NOTHING
      """,
      [@plugin_id, now]
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
        'AlienVault OTX',
        $3,
        'OTX test plugin',
        'main.wasm',
        'wasi-preview1',
        'serviceradar.plugin_result.v1',
        ($4::text)::jsonb,
        ($5::text)::jsonb,
        '{}'::jsonb,
        '{}'::jsonb,
        'upload',
        'approved',
        $6,
        '{}'::jsonb,
        ($7::text)::jsonb,
        'test-admin',
        $8,
        $8,
        $8
      )
      """,
      [
        package_id,
        @plugin_id,
        version,
        Jason.encode!(manifest),
        Jason.encode!(config_schema),
        manifest["capabilities"],
        Jason.encode!(manifest["resources"]),
        now
      ]
    )

    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one!()
  end

  defp seed_agent do
    gateway = gateway_fixture()
    agent_fixture(gateway, %{uid: "edge-otx-agent-#{System.unique_integer([:positive])}"})
  end

  defp otx_manifest(version) do
    %{
      "id" => @plugin_id,
      "name" => "AlienVault OTX",
      "version" => version,
      "description" => "Collects AlienVault OTX threat intelligence",
      "entrypoint" => "main.wasm",
      "runtime" => "wasi-preview1",
      "capabilities" => ["get_config", "log", "submit_result", "http_request"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "http" => %{
          "allowed_domains" => ["otx.alienvault.com"],
          "allowed_ports" => [443],
          "max_open_connections" => 2
        }
      }
    }
  end

  defp otx_config_schema do
    %{
      "type" => "object",
      "properties" => %{
        "base_url" => %{"type" => "string"},
        "api_key_secret_ref" => %{"type" => "string", "secretRef" => true},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
        "page" => %{"type" => "integer", "minimum" => 1},
        "timeout_ms" => %{"type" => "integer", "minimum" => 1000},
        "max_indicators" => %{"type" => "integer", "minimum" => 1, "maximum" => 5000}
      },
      "required" => ["api_key_secret_ref"]
    }
  end

  defp query!(sql, params) do
    SQL.query!(Repo, sql, params, timeout: 120_000)
  end
end
