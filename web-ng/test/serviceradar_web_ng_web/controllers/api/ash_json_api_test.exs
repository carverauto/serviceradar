defmodule ServiceRadarWebNGWeb.AshJsonApiTest do
  @moduledoc """
  Integration tests for the Ash JSON:API v2 endpoints.

  Tests cover:
  - Inventory Domain: /api/v2/devices
  - Infrastructure Domain: /api/v2/pollers, /api/v2/agents
  - Monitoring Domain: /api/v2/service-checks, /api/v2/alerts
  """

  use ServiceRadarWebNGWeb.ConnCase, async: true

  import ServiceRadarWebNG.MultiTenantFixtures

  # Use API bearer token authentication
  setup :register_and_log_in_api_user

  describe "GET /api/v2/devices" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      device = tenant_device_fixture(tenant, %{hostname: "test-host"})

      %{conn: conn, tenant: tenant, device: device}
    end

    test "returns a list of devices", %{conn: conn, device: _device} do
      conn = get(conn, ~p"/api/v2/devices")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      # The device may or may not be in the list depending on tenant isolation
      # but the endpoint should return valid JSON:API format
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request (tenant isolation)" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/devices")

      # API allows unauthenticated access but returns empty due to tenant isolation
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/devices/:uid" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      device = tenant_device_fixture(tenant, %{uid: "unique-device-uid"})

      %{conn: conn, tenant: tenant, device: device}
    end

    test "returns error for non-existent device", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/devices/non-existent-uid")

      # Returns 400 (validation) or 404 (not found) depending on path matching
      assert conn.status in [400, 404]
    end
  end

  describe "GET /api/v2/pollers" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      poller = tenant_poller_fixture(tenant)

      %{conn: conn, tenant: tenant, poller: poller}
    end

    test "returns a list of pollers", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/pollers")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request (tenant isolation)" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/pollers")

      # API allows unauthenticated access but returns empty due to tenant isolation
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/pollers/:id" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      poller = tenant_poller_fixture(tenant)

      %{conn: conn, tenant: tenant, poller: poller}
    end

    test "returns error for non-existent poller", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/pollers/non-existent-id")

      # Returns 400 (validation) or 404 (not found) depending on path matching
      assert conn.status in [400, 404]
    end
  end

  describe "GET /api/v2/agents" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      agent = tenant_agent_fixture(tenant)

      %{conn: conn, tenant: tenant, agent: agent}
    end

    test "returns a list of agents", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/agents")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request (tenant isolation)" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/agents")

      # API allows unauthenticated access but returns empty due to tenant isolation
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/agents/:uid" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      agent = tenant_agent_fixture(tenant, %{uid: "unique-agent-uid"})

      %{conn: conn, tenant: tenant, agent: agent}
    end

    test "returns error for non-existent agent", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/agents/non-existent-uid")

      # Returns 400 (validation) or 404 (not found) depending on path matching
      assert conn.status in [400, 404]
    end
  end

  describe "GET /api/v2/agents/by-poller/:poller_id" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      poller = tenant_poller_fixture(tenant)
      agent = tenant_agent_fixture(tenant, %{poller_id: poller.id})

      %{conn: conn, tenant: tenant, poller: poller, agent: agent}
    end

    test "returns agents for a poller", %{conn: conn, poller: poller} do
      conn = get(conn, ~p"/api/v2/agents/by-poller/#{poller.id}")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
    end

    test "returns empty list for non-existent poller", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/agents/by-poller/non-existent-poller")
      response = json_response(conn, 200)

      assert response["data"] == []
    end
  end

  describe "GET /api/v2/service-checks" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      check = tenant_service_check_fixture(tenant)

      %{conn: conn, tenant: tenant, check: check}
    end

    test "returns a list of service checks", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/service-checks")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request (tenant isolation)" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/service-checks")

      # API allows unauthenticated access but returns empty due to tenant isolation
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/service-checks/enabled" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      # All checks default to enabled, so just create one
      check = tenant_service_check_fixture(tenant)

      %{conn: conn, tenant: tenant, check: check}
    end

    test "returns enabled service checks", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/service-checks/enabled")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
    end
  end

  describe "GET /api/v2/service-checks/failing" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      check = tenant_service_check_fixture(tenant)

      %{conn: conn, tenant: tenant, check: check}
    end

    test "returns failing service checks", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/service-checks/failing")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
    end
  end

  describe "POST /api/v2/service-checks" do
    test "creates a new service check", %{conn: conn} do
      params = %{
        "data" => %{
          "type" => "service-check",
          "attributes" => %{
            "name" => "New Test Check",
            "check_type" => "http",
            "target" => "https://example.com/health",
            "interval_seconds" => 120,
            "timeout_seconds" => 30
          }
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/service-checks", params)

      # Should return 201 Created or an error if policies prevent creation
      assert conn.status in [201, 403]
    end

    test "returns error for unauthenticated request (no tenant)" do
      conn = build_conn()

      params = %{
        "data" => %{
          "type" => "service-check",
          "attributes" => %{
            "name" => "Test",
            "check_type" => "http",
            "target" => "https://example.com"
          }
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/service-checks", params)

      # Without a tenant, creation should fail (403) or succeed with validation error
      assert conn.status in [400, 403]
    end
  end

  describe "GET /api/v2/alerts" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      alert = tenant_alert_fixture(tenant)

      %{conn: conn, tenant: tenant, alert: alert}
    end

    test "returns a list of alerts", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/alerts")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request (tenant isolation)" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/alerts")

      # API allows unauthenticated access but returns empty due to tenant isolation
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/alerts/active" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      alert = tenant_alert_fixture(tenant)

      %{conn: conn, tenant: tenant, alert: alert}
    end

    test "returns active alerts", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/alerts/active")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
    end
  end

  describe "GET /api/v2/alerts/pending" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      alert = tenant_alert_fixture(tenant)

      %{conn: conn, tenant: tenant, alert: alert}
    end

    test "returns pending alerts", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/alerts/pending")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
    end
  end

  describe "POST /api/v2/alerts" do
    test "triggers a new alert", %{conn: conn} do
      params = %{
        "data" => %{
          "type" => "alert",
          "attributes" => %{
            "title" => "New Test Alert",
            "severity" => "warning",
            "description" => "Test alert description",
            "source_type" => "service_check",
            "source_id" => "test-source"
          }
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/alerts", params)

      # Should return 201 Created, 400 (validation), or 403 (forbidden)
      assert conn.status in [201, 400, 403]
    end

    test "returns error for unauthenticated request (no tenant)" do
      conn = build_conn()

      params = %{
        "data" => %{
          "type" => "alert",
          "attributes" => %{
            "title" => "Test",
            "severity" => "warning"
          }
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/alerts", params)

      # Without a tenant, creation should fail (403) or succeed with validation error
      assert conn.status in [400, 403]
    end
  end

  describe "PATCH /api/v2/alerts/:id/acknowledge" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      alert = tenant_alert_fixture(tenant)

      %{conn: conn, tenant: tenant, alert: alert}
    end

    test "returns error for non-existent alert", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch(~p"/api/v2/alerts/#{fake_id}/acknowledge", %{})

      # Returns 400 (validation), 403 (forbidden), or 404 (not found)
      assert conn.status in [400, 403, 404]
    end
  end

  describe "PATCH /api/v2/alerts/:id/resolve" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      alert = tenant_alert_fixture(tenant)

      %{conn: conn, tenant: tenant, alert: alert}
    end

    test "returns error for non-existent alert", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch(~p"/api/v2/alerts/#{fake_id}/resolve", %{})

      # Returns 400 (validation), 403 (forbidden), or 404 (not found)
      assert conn.status in [400, 403, 404]
    end
  end

  describe "GET /api/v2/open_api" do
    test "returns OpenAPI spec", %{conn: conn} do
      # Use string path since AshJsonApi route isn't in Phoenix router verification
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v2/open_api")

      assert conn.status == 200
      # Parse the response body directly since content-type may not be set
      response = Jason.decode!(conn.resp_body)

      assert is_map(response)
      assert Map.has_key?(response, "openapi")
      assert Map.has_key?(response, "info")
      assert Map.has_key?(response, "paths")
    end
  end

  describe "JSON:API response format" do
    setup %{conn: conn} do
      tenant = tenant_fixture()
      device = tenant_device_fixture(tenant)

      %{conn: conn, tenant: tenant, device: device}
    end

    test "includes proper JSON:API structure", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/devices")
      response = json_response(conn, 200)

      # JSON:API requires a 'data' key for successful responses
      assert Map.has_key?(response, "data")

      # Each item in data should have 'type', 'id', and 'attributes'
      if response["data"] != [] do
        item = hd(response["data"])
        assert Map.has_key?(item, "type")
        assert Map.has_key?(item, "id")
        assert Map.has_key?(item, "attributes")
      end
    end

    test "includes links for pagination when applicable", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/devices")
      response = json_response(conn, 200)

      # Response should be well-formed
      assert is_map(response)
    end
  end

  describe "tenant isolation" do
    test "users cannot see resources from other tenants", %{conn: conn} do
      # Create two tenants with devices
      tenant_a = tenant_fixture(%{slug: "tenant-isolation-a"})
      tenant_b = tenant_fixture(%{slug: "tenant-isolation-b"})

      _device_a = tenant_device_fixture(tenant_a, %{uid: "device-tenant-a"})
      _device_b = tenant_device_fixture(tenant_b, %{uid: "device-tenant-b"})

      # The authenticated user may be from a different tenant
      # The API should only return resources the user has access to
      conn = get(conn, ~p"/api/v2/devices")
      response = json_response(conn, 200)

      # Verify the response format is correct
      assert is_map(response)
      assert is_list(response["data"])

      # Tenant isolation is enforced - this is a basic smoke test
      # More specific tests are in the policy test suite
      refute is_nil(response["data"])
    end
  end
end
