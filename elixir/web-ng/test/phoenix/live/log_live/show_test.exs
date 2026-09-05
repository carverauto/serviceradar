defmodule ServiceRadarWebNGWeb.LogLive.ShowTest do
  @moduledoc """
  Tests for the Log Details LiveView (LogLive.Show).

  Covers:
  - RBAC for "Create Event Rule" button visibility
  - Rule builder modal functionality from log details
  - Attribute parsing and display
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Repo

  describe "RBAC for Create Event Rule button" do
    setup %{conn: conn} do
      {:ok, conn: conn}
    end

    test "operator can see Create Event Rule button", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, html} = live(conn, ~p"/logs/#{log_id}")

      assert has_element?(lv, "button", "Create Event Rule") or
               String.contains?(html, "Create Event Rule")
    end

    test "admin can see Create Event Rule button", %{conn: conn} do
      user = admin_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, html} = live(conn, ~p"/logs/#{log_id}")

      assert has_element?(lv, "button", "Create Event Rule") or
               String.contains?(html, "Create Event Rule")
    end

    test "viewer cannot see Create Event Rule button", %{conn: conn} do
      user = viewer_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, html} = live(conn, ~p"/logs/#{log_id}")

      refute has_element?(lv, "button", "Create Event Rule")
      refute String.contains?(html, "Create Event Rule")
    end
  end

  describe "rule builder modal from log details" do
    test "opens rule builder modal when clicking Create Event Rule", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")

      lv
      |> element("button", "Create Event Rule")
      |> render_click()

      assert has_element?(lv, "#rule_builder_modal")
      assert has_element?(lv, "h3", "Create Event Rule")
    end

    test "pre-populates rule builder from log data", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")

      lv
      |> element("button", "Create Event Rule")
      |> render_click()

      html = render(lv)
      assert html =~ "Test error message"
      assert html =~ "test-service"
    end

    test "creates promotion rule from log entry", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)
      scope = ServiceRadarWebNG.Accounts.Scope.for_user(user)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")

      lv
      |> element("button", "Create Event Rule")
      |> render_click()

      unique = System.unique_integer([:positive])
      rule_name = "log-promote-#{unique}"

      lv
      |> form("#rule-builder-form", %{
        "rule" => %{
          "name" => rule_name,
          "body_contains_enabled" => "true",
          "body_contains" => "Test error message",
          "severity_enabled" => "true",
          "severity_text" => "error",
          "service_name_enabled" => "true",
          "service_name" => "test-service"
        }
      })
      |> render_submit()

      assert_redirect(lv, ~p"/settings/rules?#{%{tab: "events"}}")

      rules = unwrap_page(Ash.read(ServiceRadar.Observability.EventRule, scope: scope))
      rule = Enum.find(rules, &(&1.name == rule_name))
      assert rule
      assert rule.match["body_contains"] == "Test error message"
      assert rule.match["severity_text"] == "error"
      assert rule.match["service_name"] == "test-service"
    end

    test "closes modal when clicking cancel", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")

      lv
      |> element("button", "Create Event Rule")
      |> render_click()

      assert has_element?(lv, "#rule_builder_modal")

      lv
      |> element("button", "Cancel")
      |> render_click()

      refute has_element?(lv, "#rule_builder_modal")
    end
  end

  describe "log detail metadata rendering" do
    @tag :web_ng_shared_fixture_db
    test "renders the effective canonical instant in the user's timezone", %{conn: conn} do
      user = operator_user_fixture()

      user =
        Ash.update!(user, %{timezone: "America/Chicago"},
          action: :update_timezone_preference,
          actor: user
        )

      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440099"
      old = Application.get_env(:serviceradar_web_ng, :srql_module)
      Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.TimestampSRQLStub)

      on_exit(fn ->
        if is_nil(old),
          do: Application.delete_env(:serviceradar_web_ng, :srql_module),
          else: Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")

      assert has_element?(
               lv,
               ~s(#log-detail-time[datetime="2026-08-30T18:00:00Z"][data-user-time-zone="America/Chicago"])
             )

      refute has_element?(lv, ~s(#log-detail-time[datetime="2026-08-30T17:00:00Z"]))

      assert has_element?(
               lv,
               ~s(time#log-signal-display-widget-3-field-1-time[datetime="2026-08-30T18:00:00.000000000Z"][data-user-time-zone="America/Chicago"])
             )

      render_click(lv, "copy_json", %{})
      assert_push_event(lv, "clipboard", %{text: copied_json})
      copied = Jason.decode!(copied_json)

      assert copied["observed_timestamp"] == "2026-08-30T18:00:00Z"
      assert copied["timestamp"] == "2026-08-30T12:34:56"
      refute copied_json =~ "America/Chicago"

      stream_times =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#log-stream time")

      stream_ids = LazyHTML.attribute(stream_times, "id")

      assert length(stream_ids) == 3
      assert stream_ids == Enum.uniq(stream_ids)
      assert LazyHTML.attribute(stream_times, "datetime") == List.duplicate("2026-08-30T18:00:00Z", 3)
      assert LazyHTML.attribute(stream_times, "data-user-time-zone") == List.duplicate("America/Chicago", 3)

      stable_ids =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#log-stream time")
        |> LazyHTML.attribute("id")

      assert stable_ids == stream_ids
    end

    @tag :web_ng_shared_fixture_db
    test "keeps a source-only offset-less timestamp as raw fallback text", %{conn: conn} do
      user = operator_user_fixture()

      user =
        Ash.update!(user, %{timezone: "America/Chicago"},
          action: :update_timezone_preference,
          actor: user
        )

      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440098"
      old = Application.get_env(:serviceradar_web_ng, :srql_module)
      Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.TimestampSRQLStub)

      on_exit(fn ->
        if is_nil(old),
          do: Application.delete_env(:serviceradar_web_ng, :srql_module),
          else: Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")
      html = render(lv)

      assert html =~ "2026-08-30T12:45:56"
      refute has_element?(lv, "time#log-detail-time")
      refute html =~ "2026-08-30T12:45:56Z"
    end

    test "renders resource attributes section when present", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")

      assert has_element?(lv, "span", "Resource Attributes")
      assert has_element?(lv, "span", "service.name")
      assert has_element?(lv, "span", "service.version")
    end

    test "shows collector target and error from log attributes", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "7c2f1a90-4b11-4d8e-9c3a-0b1c2d3e4f50"
      insert_test_collector_error_log!(log_id)

      {:ok, lv, html} = live(conn, ~p"/logs/#{log_id}")

      assert has_element?(lv, "span", "Target")
      assert html =~ "edge-switch-01"
      assert html =~ "snmp: timeout waiting for response"
      assert has_element?(lv, "span", "Error")
      assert has_element?(lv, "span", "Resource Attributes")
    end

    test "renders the collector-observed source IP", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")

      assert has_element?(lv, "#log-source-ip", "Source IP")
      assert has_element?(lv, "#log-source-ip", "192.0.2.10")
    end

    test "derives resource and scope fields from nested attributes", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "b661cddf-7e67-4fb4-873d-68e9dde54bf3"
      insert_test_log_with_nested_attributes!(log_id)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")

      assert has_element?(lv, "span", "service.name")
      assert has_element?(lv, "span", "serviceradar-db-event-writer")
      assert has_element?(lv, "span", "db-writer-service")
    end

    test "renders source as a device link when the source IP is in inventory", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      device =
        device_fixture(%{
          uid: "device-snmp-source",
          name: "aruba-24g-02",
          ip: "192.168.10.154"
        })

      log_id = "9f53ba9d-aacf-4580-ae67-a36dab67ae0f"
      insert_test_snmp_log!(log_id)

      {:ok, lv, _html} = live(conn, ~p"/logs/#{log_id}")

      assert has_element?(lv, "a[href='/devices/#{device.uid}']", "192.168.10.154:161")
    end

    test "renders Erlang logger charlists as readable metadata", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "59f490f9-b7c9-4570-b8d1-9c1095f45014"
      insert_test_erlang_metadata_log!(log_id)

      {:ok, _lv, html} = live(conn, ~p"/logs/#{log_id}")

      assert html =~ "lib/serviceradar/observability/zen_rule_sync.ex"
      assert html =~ "Elixir.ServiceRadar.Observability.ZenRuleSync.log_reconcile_results/1"
      refute html =~ "[108,105,98"
    end

    test "renders logs with blank resource attributes", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "46f1addc-839f-49ba-abca-54e4424638df"
      insert_test_blank_resource_log!(log_id)

      {:ok, _lv, html} = live(conn, ~p"/logs/#{log_id}")

      assert html =~ "regular syslog message"
      refute html =~ "FunctionClauseError"
    end

    test "redacts sensitive NATS credentials in message body and attributes", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "67d95c6e-b342-47bc-a43e-05ca39cb7528"
      insert_sensitive_nats_log!(log_id)

      {:ok, _lv, html} = live(conn, ~p"/logs/#{log_id}")

      assert html =~ "nkey_seed"
      assert html =~ "[REDACTED]"
      refute html =~ "SENSITIVE_NKEY"
      refute html =~ "SENSITIVE_JWT"
      refute html =~ "SENSITIVE_ATTR_TOKEN"
    end

    test "normalizes the OTel SeverityNumber enum name into a colored badge", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      # OTel-SDK producers write the raw SeverityNumber enum name into
      # severity_text; the detail badge must resolve it to a label + color.
      log_id = "a1b2c3d4-0000-4000-8000-000000000001"
      insert_test_otel_severity_log!(log_id, "SEVERITY_NUMBER_INFO")

      {:ok, _lv, html} = live(conn, ~p"/logs/#{log_id}")

      assert html =~ "badge-info"
      assert html =~ ~r/badge-info[^>]*>\s*INFO\s*</
      # Neither the raw enum name nor an upcased copy of it may reach the badge.
      refute html =~ "SEVERITY_NUMBER_INFO"
      refute html =~ ">SEVERITY NUMBER INFO<"
    end

    test "normalizes a numbered OTel SeverityNumber variant into a WARN badge", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "a1b2c3d4-0000-4000-8000-000000000002"
      insert_test_otel_severity_log!(log_id, "SEVERITY_NUMBER_WARN3")

      {:ok, _lv, html} = live(conn, ~p"/logs/#{log_id}")

      # The trailing numbered-variant digit is stripped: WARN3 -> WARN.
      assert html =~ "badge-warning"
      assert html =~ ~r/badge-warning[^>]*>\s*WARN\s*</
      refute html =~ "SEVERITY_NUMBER_WARN3"
    end

    test "renders ingest identity fields when present", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      log_id = "7c0e98aa-1a55-4dd2-9c41-3210fe5da7bd"
      insert_test_ingest_log!(log_id)

      {:ok, lv, html} = live(conn, ~p"/logs/#{log_id}")

      assert html =~ "Ingest Identity"
      assert has_element?(lv, "#log-ingest-identity", "spiffe://sr/agent/edge-1")
      assert has_element?(lv, "#log-ingest-agent", "agent-edge-1")
      assert has_element?(lv, "#log-ingest-partition", "tenant-a")
    end

    test "omits ingest identity fields when blank", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      # insert_test_log! leaves the ingest columns at their NOT NULL
      # DEFAULT '' values, which must not render.
      log_id = "550e8400-e29b-41d4-a716-446655440000"
      insert_test_log!(log_id)

      {:ok, lv, html} = live(conn, ~p"/logs/#{log_id}")

      refute html =~ "Ingest Identity"
      refute has_element?(lv, "#log-ingest-identity")
      refute has_element?(lv, "#log-ingest-agent")
      refute has_element?(lv, "#log-ingest-partition")
    end
  end

  describe "can_create_rules? helper" do
    test "returns true for operator role" do
      assert can_create_rules?(%{user: %{role: :operator}})
    end

    test "returns true for admin role" do
      assert can_create_rules?(%{user: %{role: :admin}})
    end

    test "returns false for viewer role" do
      refute can_create_rules?(%{user: %{role: :viewer}})
    end

    test "returns false for nil user" do
      refute can_create_rules?(nil)
    end

    test "returns false for missing role" do
      refute can_create_rules?(%{user: %{}})
    end
  end

  # Test helper that mirrors the component's RBAC check
  defp can_create_rules?(%{user: %{role: role}}) when role in [:operator, :admin], do: true
  defp can_create_rules?(_), do: false

  defp insert_test_collector_error_log!(log_id) when is_binary(log_id) do
    {:ok, uuid} = Ecto.UUID.dump(log_id)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("logs", [
      %{
        timestamp: now,
        observed_timestamp: now,
        id: uuid,
        severity_text: "ERROR",
        severity_number: 17,
        body: "Error collecting from target",
        service_name: "serviceradar-agent",
        scope_name: "agent",
        attributes:
          Jason.encode!(%{
            "error" => "snmp: timeout waiting for response",
            "target_name" => "edge-switch-01"
          }),
        resource_attributes:
          Jason.encode!(%{
            "service.name" => "serviceradar-agent",
            "service.version" => "1.0.0"
          }),
        created_at: now
      }
    ])
  end

  defp insert_test_log!(log_id) when is_binary(log_id) do
    {:ok, uuid} = Ecto.UUID.dump(log_id)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("logs", [
      %{
        timestamp: now,
        observed_timestamp: now,
        id: uuid,
        severity_text: "ERROR",
        severity_number: 17,
        body: "Test error message",
        service_name: "test-service",
        service_version: "1.0.0",
        service_instance: "test-instance",
        source_ip: "192.0.2.10",
        scope_name: "test-scope",
        scope_version: "1.0.0",
        attributes: Jason.encode!(%{"error" => "connection failed"}),
        resource_attributes: Jason.encode!(%{"service.name" => "test-service", "service.version" => "1.0.0"}),
        created_at: now
      }
    ])
  end

  defp insert_test_otel_severity_log!(log_id, severity_text) when is_binary(log_id) and is_binary(severity_text) do
    {:ok, uuid} = Ecto.UUID.dump(log_id)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    # OTel-SDK producers leave severity_number null and carry the raw enum name.
    Repo.insert_all("logs", [
      %{
        timestamp: now,
        observed_timestamp: now,
        id: uuid,
        severity_text: severity_text,
        body: "otel-severity message",
        service_name: "otel-service",
        attributes: Jason.encode!(%{"event" => "otel"}),
        created_at: now
      }
    ])
  end

  defmodule TimestampSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @log %{
      "id" => "550e8400-e29b-41d4-a716-446655440099",
      "timestamp" => "2026-08-30T12:34:56",
      "observed_timestamp" => "2026-08-30T18:00:00Z",
      "time" => "2026-08-30T18:00:00Z",
      "severity_text" => "INFO",
      "service_name" => "syslog",
      "body" => "syslog effective timestamp",
      "source" => "syslog",
      "attributes" => %{"source_timestamp" => "Aug 30 12:34:56"},
      "query" => %{"hostname" => "example.test"},
      "metadata" => %{
        "service_radar" => %{
          "observed_time_unix_nano" => 1_788_112_800_000_000_000,
          "signal_schema" => %{
            "producer_id" => "powerdns",
            "producer_version" => "0.1.1",
            "schema_id" => "com.carverauto.powerdns.dns_activity",
            "schema_version" => "1.0.0"
          }
        }
      }
    }

    def query(query), do: query(query, %{})

    def query(query, _opts) do
      results =
        cond do
          String.contains?(query, "550e8400-e29b-41d4-a716-446655440098") ->
            [source_only_log()]

          String.contains?(query, ~s(id:")) ->
            [@log]

          true ->
            idless = Map.delete(@log, "id")
            [idless, idless]
        end

      {:ok, %{"results" => results}}
    end

    def query_request(%{"query" => query}), do: query(query)
    def query_request(_), do: {:error, :invalid_request}

    defp source_only_log do
      @log
      |> Map.put("id", "550e8400-e29b-41d4-a716-446655440098")
      |> Map.put("timestamp", "2026-08-30T12:45:56")
      |> Map.put("time", "2026-08-30T12:45:56")
      |> Map.put("body", "source-only unzoned timestamp")
      |> Map.delete("observed_timestamp")
    end
  end

  defp insert_test_log_with_nested_attributes!(log_id) when is_binary(log_id) do
    {:ok, uuid} = Ecto.UUID.dump(log_id)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("logs", [
      %{
        timestamp: now,
        observed_timestamp: now,
        id: uuid,
        severity_text: "INFO",
        severity_number: 9,
        body: "ProcessBatch called",
        service_name: "serviceradar-db-event-writer",
        scope_name: "db-writer-service",
        scope_version: "1.0.0",
        attributes:
          Jason.encode!(%{
            "attributes" => %{"message_count" => "1"},
            "resource" => %{
              "service.name" => "serviceradar-db-event-writer",
              "service.version" => "1.0.0"
            },
            "scope" => "db-writer-service"
          }),
        created_at: now
      }
    ])
  end

  defp insert_test_snmp_log!(log_id) when is_binary(log_id) do
    {:ok, uuid} = Ecto.UUID.dump(log_id)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("logs", [
      %{
        timestamp: now,
        observed_timestamp: now,
        id: uuid,
        severity_text: "INFO",
        severity_number: 11,
        body: "SNMP trap received",
        source: "snmp",
        attributes: Jason.encode!(%{"version" => "V1"}),
        resource_attributes: Jason.encode!(%{"source" => "192.168.10.154:161"}),
        created_at: now
      }
    ])
  end

  defp insert_test_erlang_metadata_log!(log_id) when is_binary(log_id) do
    {:ok, uuid} = Ecto.UUID.dump(log_id)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("logs", [
      %{
        timestamp: now,
        observed_timestamp: now,
        id: uuid,
        severity_text: "INFO",
        severity_number: 9,
        body: "Zen rule reconcile summary: total=13 success=0 failed=1 transient_failed=12",
        service_name: "serviceradar-core-elx",
        attributes:
          Jason.encode!(%{
            "file" => ~c"lib/serviceradar/observability/zen_rule_sync.ex",
            "mfa" => ["Elixir.ServiceRadar.Observability.ZenRuleSync", "log_reconcile_results", 1]
          }),
        created_at: now
      }
    ])
  end

  defp insert_test_ingest_log!(log_id) when is_binary(log_id) do
    {:ok, uuid} = Ecto.UUID.dump(log_id)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("logs", [
      %{
        timestamp: now,
        observed_timestamp: now,
        id: uuid,
        severity_text: "INFO",
        severity_number: 9,
        body: "ingest-attributed message",
        service_name: "test-service",
        attributes: Jason.encode!(%{"event" => "ingest"}),
        created_at: now,
        ingest_identity: "spiffe://sr/agent/edge-1",
        ingest_agent_id: "agent-edge-1",
        ingest_partition: "tenant-a"
      }
    ])
  end

  defp insert_test_blank_resource_log!(log_id) when is_binary(log_id) do
    {:ok, uuid} = Ecto.UUID.dump(log_id)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("logs", [
      %{
        timestamp: now,
        observed_timestamp: now,
        id: uuid,
        severity_text: "INFO",
        severity_number: 11,
        body: "regular syslog message",
        source: "syslog",
        attributes: Jason.encode!(%{}),
        resource_attributes: "",
        created_at: now
      }
    ])
  end

  defp insert_sensitive_nats_log!(log_id) when is_binary(log_id) do
    {:ok, uuid} = Ecto.UUID.dump(log_id)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("logs", [
      %{
        timestamp: now,
        observed_timestamp: now,
        id: uuid,
        severity_text: "ERROR",
        severity_number: 17,
        body:
          ~S|#{label => {gen_server,terminate},state => #{nkey_seed => <<"SENSITIVE_NKEY">>,jwt => <<"SENSITIVE_JWT">>}}|,
        service_name: "serviceradar-web-ng",
        attributes: Jason.encode!(%{"token" => "SENSITIVE_ATTR_TOKEN", "safe" => "kept"}),
        resource_attributes: Jason.encode!(%{"service.name" => "serviceradar-web-ng"}),
        created_at: now
      }
    ])
  end

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []
end
