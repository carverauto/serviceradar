defmodule ServiceRadarWebNGWeb.LogLive.ShowTest do
  @moduledoc """
  Tests for the Log Details LiveView (LogLive.Show).

  Covers:
  - RBAC for "Create Event Rule" button visibility
  - Rule builder modal functionality from log details
  - Attribute parsing and display
  """

  use ServiceRadarWebNGWeb.ConnCase, async: true
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
        scope_name: "test-scope",
        scope_version: "1.0.0",
        attributes: Jason.encode!(%{"error" => "connection failed"}),
        resource_attributes: Jason.encode!(%{"service.name" => "test-service", "service.version" => "1.0.0"}),
        created_at: now
      }
    ])
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

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []
end
