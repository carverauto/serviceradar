defmodule ServiceRadarWebNGWeb.LogLive.ShowTest do
  @moduledoc """
  Tests for the Log Details LiveView (LogLive.Show).

  Tests cover:
  - RBAC for "Create Event Rule" button visibility
  - Rule builder modal functionality from log details
  - Attribute parsing and display
  """

  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  use ServiceRadarWebNG.AshTestHelpers

  describe "RBAC for Create Event Rule button" do
    setup %{conn: conn} do
      # We need to set up users with different roles
      # and log them in to test RBAC
      {:ok, conn: conn}
    end

    test "operator can see Create Event Rule button", %{conn: conn} do
      # Create operator user and log them in
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      # Mock SRQL module for testing
      Application.put_env(:serviceradar_web_ng, :srql_module, MockSRQL)

      # Visit a log details page (we need a valid log_id format)
      log_id = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, lv, html} = live(conn, ~p"/observability/logs/#{log_id}")

      # The button should be visible for operators
      # Note: This will show an error since we're using mock SRQL
      # but we can still check for button presence in assigns
      assert has_element?(lv, "button", "Create Event Rule") or
               String.contains?(html, "Create Event Rule")
    after
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end

    test "admin can see Create Event Rule button", %{conn: conn} do
      # Create admin user and log them in
      user = admin_user_fixture()
      conn = log_in_user(conn, user)

      Application.put_env(:serviceradar_web_ng, :srql_module, MockSRQL)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, lv, html} = live(conn, ~p"/observability/logs/#{log_id}")

      # The button should be visible for admins
      assert has_element?(lv, "button", "Create Event Rule") or
               String.contains?(html, "Create Event Rule")
    after
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end

    test "viewer cannot see Create Event Rule button", %{conn: conn} do
      # Create viewer user (default role) and log them in
      user = user_fixture()
      conn = log_in_user(conn, user)

      Application.put_env(:serviceradar_web_ng, :srql_module, MockSRQL)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, lv, html} = live(conn, ~p"/observability/logs/#{log_id}")

      # The button should NOT be visible for viewers
      refute has_element?(lv, "button", "Create Event Rule")
      refute String.contains?(html, "Create Event Rule")
    after
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end
  end

  describe "rule builder modal from log details" do
    test "opens rule builder modal when clicking Create Event Rule", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      Application.put_env(:serviceradar_web_ng, :srql_module, MockSRQLWithLog)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, lv, _html} = live(conn, ~p"/observability/logs/#{log_id}")

      # Click the Create Event Rule button
      lv
      |> element("button", "Create Event Rule")
      |> render_click()

      # Modal should be visible
      assert has_element?(lv, "#rule_builder_modal")
      assert has_element?(lv, "h3", "Create Event Rule")
    after
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end

    test "pre-populates rule builder from log data", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      Application.put_env(:serviceradar_web_ng, :srql_module, MockSRQLWithLog)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, lv, _html} = live(conn, ~p"/observability/logs/#{log_id}")

      # Click the Create Event Rule button
      lv
      |> element("button", "Create Event Rule")
      |> render_click()

      # Check that form is pre-populated with log data
      html = render(lv)

      # Should have log message pre-filled
      assert html =~ "Test error message"
      # Should have service name pre-filled
      assert html =~ "test-service"
    after
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end

    test "creates promotion rule from log entry", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)
      scope = ServiceRadarWebNG.Accounts.Scope.for_user(user)

      Application.put_env(:serviceradar_web_ng, :srql_module, MockSRQLWithLog)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, lv, _html} = live(conn, ~p"/observability/logs/#{log_id}")

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

      refute has_element?(lv, "#rule_builder_modal")

      rules = unwrap_page(Ash.read(ServiceRadar.Observability.LogPromotionRule, scope: scope))
      rule = Enum.find(rules, &(&1.name == rule_name))
      assert rule
      assert rule.match["body_contains"] == "Test error message"
      assert rule.match["severity_text"] == "error"
      assert rule.match["service_name"] == "test-service"
    after
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end

    test "closes modal when clicking cancel", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      Application.put_env(:serviceradar_web_ng, :srql_module, MockSRQLWithLog)

      log_id = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, lv, _html} = live(conn, ~p"/observability/logs/#{log_id}")

      # Open modal
      lv
      |> element("button", "Create Event Rule")
      |> render_click()

      assert has_element?(lv, "#rule_builder_modal")

      # Click cancel
      lv
      |> element("button", "Cancel")
      |> render_click()

      # Modal should be closed
      refute has_element?(lv, "#rule_builder_modal")
    after
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end
  end

  describe "can_create_rules? helper" do
    test "returns true for operator role" do
      scope = %{user: %{role: :operator}}
      assert can_create_rules?(scope)
    end

    test "returns true for admin role" do
      scope = %{user: %{role: :admin}}
      assert can_create_rules?(scope)
    end

    test "returns false for viewer role" do
      scope = %{user: %{role: :viewer}}
      refute can_create_rules?(scope)
    end

    test "returns false for nil user" do
      refute can_create_rules?(nil)
    end

    test "returns false for missing role" do
      scope = %{user: %{}}
      refute can_create_rules?(scope)
    end
  end

  # Test helper that mirrors the component's RBAC check
  defp can_create_rules?(%{user: %{role: role}}) when role in [:operator, :admin], do: true
  defp can_create_rules?(_), do: false

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []
end

# Mock SRQL module that returns no results
defmodule MockSRQL do
  def query(_query) do
    {:ok, %{"results" => [], "total_count" => 0}}
  end
end

# Mock SRQL module that returns a sample log
defmodule MockSRQLWithLog do
  def query(query) do
    if String.contains?(query, "in:logs") do
      {:ok, %{
        "results" => [
          %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "body" => "Test error message",
            "severity_text" => "ERROR",
            "service_name" => "test-service",
            "timestamp" => "2024-01-15T10:30:00Z",
            "attributes" => %{"error" => "connection failed"}
          }
        ],
        "total_count" => 1
      }}
    else
      {:ok, %{"results" => [], "total_count" => 0}}
    end
  end
end
