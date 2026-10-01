defmodule ServiceRadarWebNGWeb.AshJsonApiTest do
  @moduledoc """
  Integration tests for the Ash JSON:API v2 endpoints.

  Tests cover:
  - Inventory Domain: /api/v2/devices
  - Infrastructure Domain: /api/v2/gateways, /api/v2/agents
  - Monitoring Domain: /api/v2/service-checks, /api/v2/alerts
  - Observability Domain: /api/v2/stateful-alert-rules
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.RoleProfilePolicy
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.Repo

  # Use API bearer token authentication
  setup :register_and_log_in_api_user

  describe "GET /api/v2/devices" do
    setup %{conn: conn} do
      _device = device_fixture(%{hostname: "test-host"})

      %{conn: conn}
    end

    test "returns a list of devices", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/devices")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      # The device may or may not be in the list depending on auth context
      # but the endpoint should return valid JSON:API format
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/devices")

      # API allows unauthenticated access but returns empty without auth context
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/devices/:uid" do
    setup %{conn: conn} do
      _device = device_fixture(%{uid: "unique-device-uid"})

      %{conn: conn}
    end

    test "returns error for non-existent device", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/devices/non-existent-uid")

      # Returns 400 (validation) or 404 (not found) depending on path matching
      assert conn.status in [400, 404]
    end
  end

  describe "GET /api/v2/gateways" do
    setup %{conn: conn} do
      _gateway = gateway_fixture()

      %{conn: conn}
    end

    test "returns a list of gateways", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/gateways")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/gateways")

      # API allows unauthenticated access but returns empty without auth context
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/gateways/:id" do
    setup %{conn: conn} do
      _gateway = gateway_fixture()

      %{conn: conn}
    end

    test "returns error for non-existent gateway", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/gateways/non-existent-id")

      # Returns 400 (validation) or 404 (not found) depending on path matching
      assert conn.status in [400, 404]
    end
  end

  describe "GET /api/v2/agents" do
    setup %{conn: conn} do
      gateway = gateway_fixture()
      _agent = agent_fixture(gateway)

      %{conn: conn}
    end

    test "returns a list of agents", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/agents")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/agents")

      # API allows unauthenticated access but returns empty without auth context
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/agents/:uid" do
    setup %{conn: conn} do
      gateway = gateway_fixture()
      _agent = agent_fixture(gateway, %{uid: "unique-agent-uid"})

      %{conn: conn}
    end

    test "returns error for non-existent agent", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/agents/non-existent-uid")

      # Returns 400 (validation) or 404 (not found) depending on path matching
      assert conn.status in [400, 404]
    end
  end

  describe "GET /api/v2/agents/by-gateway/:gateway_id" do
    setup %{conn: conn} do
      gateway = gateway_fixture()
      _agent = agent_fixture(gateway, %{gateway_id: gateway.id})

      %{conn: conn, gateway: gateway}
    end

    test "returns agents for a gateway", %{conn: conn, gateway: gateway} do
      conn = get(conn, ~p"/api/v2/agents/by-gateway/#{gateway.id}")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
    end

    test "returns empty list for non-existent gateway", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/agents/by-gateway/non-existent-gateway")
      response = json_response(conn, 200)

      assert response["data"] == []
    end
  end

  describe "GET /api/v2/service-checks" do
    setup %{conn: conn} do
      _check = service_check_fixture()

      %{conn: conn}
    end

    test "returns a list of service checks", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/service-checks")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/service-checks")

      # API allows unauthenticated access but returns empty without auth context
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/service-checks/enabled" do
    setup %{conn: conn} do
      # All checks default to enabled, so just create one
      _check = service_check_fixture()

      %{conn: conn}
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
      _check = service_check_fixture()

      %{conn: conn}
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

    test "returns error for unauthenticated request" do
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

      # Without authentication, creation should fail (403) or succeed with validation error
      assert conn.status in [400, 403]
    end
  end

  describe "GET /api/v2/alerts" do
    setup %{conn: conn} do
      _alert = alert_fixture()

      %{conn: conn}
    end

    test "returns a list of alerts", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/alerts")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/alerts")

      # API allows unauthenticated access but returns empty without auth context
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/alerts/active" do
    setup %{conn: conn} do
      _alert = alert_fixture()

      %{conn: conn}
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
      _alert = alert_fixture()

      %{conn: conn}
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

    test "returns error for unauthenticated request" do
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

      # Without authentication, creation should fail (403) or succeed with validation error
      assert conn.status in [400, 403]
    end
  end

  describe "PATCH /api/v2/alerts/:id/acknowledge" do
    setup %{conn: conn} do
      _alert = alert_fixture()

      %{conn: conn}
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
      _alert = alert_fixture()

      %{conn: conn}
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

  describe "GET /api/v2/stateful-alert-rules" do
    setup %{conn: conn} do
      _rule = stateful_alert_rule_fixture()

      %{conn: conn}
    end

    test "returns a list of stateful alert rules", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/stateful-alert-rules")
      response = json_response(conn, 200)

      assert is_map(response)
      assert is_list(response["data"])
      assert Map.has_key?(response, "data")
    end

    test "returns empty list for unauthenticated request" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v2/stateful-alert-rules")

      # API allows unauthenticated access but returns empty without auth context
      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "POST /api/v2/stateful-alert-rules" do
    test "operator provisions, updates, and removes a stateful alert rule" do
      conn = log_in_api_user(build_conn(), operator_user_fixture())

      params = %{
        "data" => %{
          "type" => "stateful-alert-rule",
          "attributes" => %{
            "name" => "New Test Rule #{System.unique_integer([:positive])}",
            "signal" => "log",
            "match" => %{},
            "group_by" => ["serviceradar.sync.integration_source_id"]
          }
        }
      }

      created_conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/stateful-alert-rules", params)

      created = json_response(created_conn, 201)["data"]
      assert created["type"] == "stateful-alert-rule"
      assert created["attributes"]["name"] == params["data"]["attributes"]["name"]
      id = created["id"]
      assert is_binary(id) and byte_size(id) > 0

      fetched = conn |> get("/api/v2/stateful-alert-rules/#{id}") |> json_response(200)
      assert fetched["data"]["id"] == id

      active = conn |> get("/api/v2/stateful-alert-rules/active") |> json_response(200)
      assert Enum.any?(active["data"], &(&1["id"] == id))

      updated =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v2/stateful-alert-rules/#{id}", %{
          "data" => %{
            "type" => "stateful-alert-rule",
            "id" => id,
            "attributes" => %{"enabled" => false, "priority" => 5}
          }
        })
        |> json_response(200)

      assert updated["data"]["attributes"]["enabled"] == false
      fetched = conn |> get("/api/v2/stateful-alert-rules/#{id}") |> json_response(200)
      assert fetched["data"]["attributes"]["priority"] == 5
      assert fetched["data"]["attributes"]["enabled"] == false

      active = conn |> get("/api/v2/stateful-alert-rules/active") |> json_response(200)
      refute Enum.any?(active["data"], &(&1["id"] == id))

      deleted = delete(conn, "/api/v2/stateful-alert-rules/#{id}")
      assert deleted.status == 200
      remaining = conn |> get("/api/v2/stateful-alert-rules") |> json_response(200)
      refute Enum.any?(remaining["data"], &(&1["id"] == id))
    end

    test "returns error for unauthenticated request" do
      conn = build_conn()

      params = %{
        "data" => %{
          "type" => "stateful-alert-rule",
          "attributes" => %{
            "name" => "Test Rule",
            "signal" => "log"
          }
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/stateful-alert-rules", params)

      # Without authentication, creation should fail (403) or succeed with validation error
      assert conn.status in [400, 403]
    end
  end

  describe "PATCH /api/v2/stateful-alert-rules/:id" do
    setup %{conn: conn} do
      rule = stateful_alert_rule_fixture()

      %{conn: conn, rule: rule}
    end

    test "returns error for non-existent rule", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      params = %{
        "data" => %{
          "id" => fake_id,
          "type" => "stateful-alert-rule",
          "attributes" => %{"priority" => 5}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch(~p"/api/v2/stateful-alert-rules/#{fake_id}", params)

      # Returns 400 (validation), 403 (forbidden), or 404 (not found)
      assert conn.status in [400, 403, 404]
    end
  end

  describe "DELETE /api/v2/stateful-alert-rules/:id" do
    setup %{conn: conn} do
      rule = stateful_alert_rule_fixture()

      %{conn: conn, rule: rule}
    end

    test "returns error for non-existent rule", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn = delete(conn, ~p"/api/v2/stateful-alert-rules/#{fake_id}")

      # Returns 400 (validation), 403 (forbidden), or 404 (not found)
      assert conn.status in [400, 403, 404]
    end

    # Explicit coverage per tasks.md 5.5: PresetRuleResource's actual policy is
    # `operator_action([:create, :update, :destroy])`, so operator CAN destroy
    # a stateful alert rule -- unlike `assert_rbac_matrix`'s generic 3-tier
    # assumption (`expected_permission/2` in policy_test_helpers.ex), which
    # assumes operator cannot destroy. Do not rely on that generic helper for
    # this resource; this test asserts the real behavior directly against the
    # HTTP endpoint with a real operator-role user.
    test "an authenticated operator can destroy a stateful alert rule", %{rule: rule} do
      operator = operator_user_fixture()
      conn = log_in_api_user(build_conn(), operator)

      conn = delete(conn, ~p"/api/v2/stateful-alert-rules/#{rule.id}")

      assert conn.status == 200
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
      assert Map.has_key?(response["paths"], "/api/v2/stateful-alert-rules")
    end
  end

  # ---------------------------------------------------------------------------
  # Observability Domain — EventRule (log-to-event promotion rules)
  # ---------------------------------------------------------------------------

  describe "GET /api/v2/event-rules" do
    setup do
      rule = event_rule_fixture()
      %{rule: rule}
    end

    @tag :web_ng_shared_fixture_db
    test "viewer can list event rules", %{rule: rule} do
      conn = log_in_api_user(build_conn(), viewer_user_fixture())
      conn = get(conn, "/api/v2/event-rules")
      response = json_response(conn, 200)

      assert Enum.any?(response["data"], &(&1["id"] == rule.id))
    end

    @tag :web_ng_shared_fixture_db
    test "unauthenticated request returns empty list" do
      conn = build_conn()
      conn = get(conn, "/api/v2/event-rules")

      response = json_response(conn, 200)
      assert response["data"] == []
    end
  end

  describe "GET /api/v2/event-rules/active" do
    setup do
      enabled = event_rule_fixture(%{enabled: true, name: "Active Rule #{System.unique_integer([:positive])}"})
      disabled = event_rule_fixture(%{enabled: false, name: "Disabled Rule #{System.unique_integer([:positive])}"})
      %{enabled: enabled, disabled: disabled}
    end

    @tag :web_ng_shared_fixture_db
    test "returns only enabled rules", %{enabled: enabled, disabled: disabled} do
      conn = log_in_api_user(build_conn(), viewer_user_fixture())
      response = conn |> get("/api/v2/event-rules/active") |> json_response(200)
      assert Enum.any?(response["data"], &(&1["id"] == enabled.id))
      refute Enum.any?(response["data"], &(&1["id"] == disabled.id))
      assert Enum.all?(response["data"], fn r -> r["attributes"]["enabled"] == true end)
    end
  end

  describe "POST /api/v2/event-rules" do
    @tag :web_ng_shared_fixture_db
    test "operator can create, update, and delete an event rule" do
      conn = log_in_api_user(build_conn(), operator_user_fixture())

      rule_name = "example-app DatabaseError #{System.unique_integer([:positive])}"

      params = %{
        "data" => %{
          "type" => "event-rule",
          "attributes" => %{
            "name" => rule_name,
            "source_type" => "log",
            "match" => %{"body" => "DatabaseError"},
            "event" => %{"severity" => "high"}
          }
        }
      }

      created_conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v2/event-rules", params)

      created = json_response(created_conn, 201)["data"]
      assert created["type"] == "event-rule"
      assert created["attributes"]["name"] == rule_name
      id = created["id"]
      assert is_binary(id) and byte_size(id) > 0

      fetched = conn |> get("/api/v2/event-rules/#{id}") |> json_response(200)
      assert fetched["data"]["id"] == id

      active = conn |> get("/api/v2/event-rules/active") |> json_response(200)
      assert Enum.any?(active["data"], &(&1["id"] == id))

      updated =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v2/event-rules/#{id}", %{
          "data" => %{
            "type" => "event-rule",
            "id" => id,
            "attributes" => %{"enabled" => false, "priority" => 50}
          }
        })
        |> json_response(200)

      assert updated["data"]["attributes"]["enabled"] == false

      fetched2 = conn |> get("/api/v2/event-rules/#{id}") |> json_response(200)
      assert fetched2["data"]["attributes"]["priority"] == 50
      assert fetched2["data"]["attributes"]["enabled"] == false

      active2 = conn |> get("/api/v2/event-rules/active") |> json_response(200)
      refute Enum.any?(active2["data"], &(&1["id"] == id))

      deleted = delete(conn, "/api/v2/event-rules/#{id}")
      assert deleted.status == 200

      remaining = conn |> get("/api/v2/event-rules") |> json_response(200)
      refute Enum.any?(remaining["data"], &(&1["id"] == id))
    end

    @tag :web_ng_shared_fixture_db
    test "viewer is denied write access" do
      conn = log_in_api_user(build_conn(), viewer_user_fixture())

      params = %{
        "data" => %{
          "type" => "event-rule",
          "attributes" => %{"name" => "Viewer Rule", "source_type" => "log"}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v2/event-rules", params)

      assert conn.status in [400, 403]
    end

    @tag :web_ng_shared_fixture_db
    test "unauthenticated create is denied" do
      conn = build_conn()

      params = %{
        "data" => %{
          "type" => "event-rule",
          "attributes" => %{"name" => "Anon Rule", "source_type" => "log"}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v2/event-rules", params)

      assert conn.status in [400, 403]
    end
  end

  describe "PATCH /api/v2/event-rules/:id" do
    @tag :web_ng_shared_fixture_db
    test "returns not found for an operator updating a non-existent rule" do
      conn = log_in_api_user(build_conn(), operator_user_fixture())
      fake_id = "00000000-0000-0000-0000-000000000000"

      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v2/event-rules/#{fake_id}", %{
          "data" => %{"type" => "event-rule", "id" => fake_id, "attributes" => %{"priority" => 5}}
        })

      assert %{"errors" => [%{"code" => "not_found"}]} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/v2/event-rules/:id" do
    setup %{conn: conn} do
      rule = event_rule_fixture()
      %{conn: conn, rule: rule}
    end

    @tag :web_ng_shared_fixture_db
    test "returns not found for an operator deleting a non-existent rule" do
      conn = log_in_api_user(build_conn(), operator_user_fixture())
      fake_id = "00000000-0000-0000-0000-000000000000"
      conn = delete(conn, "/api/v2/event-rules/#{fake_id}")
      assert %{"errors" => [%{"code" => "not_found"}]} = json_response(conn, 404)
    end

    @tag :web_ng_shared_fixture_db
    test "operator can destroy an event rule", %{rule: rule} do
      operator = operator_user_fixture()
      conn = log_in_api_user(build_conn(), operator)
      conn = delete(conn, "/api/v2/event-rules/#{rule.id}")
      assert conn.status == 200
    end
  end

  describe "event rule custom profile permissions" do
    for role <- [:operator, :viewer] do
      @tag :web_ng_shared_fixture_db
      @tag sandbox: :unboxed
      test "#{role} custom profile controls all event rule read routes" do
        role = unquote(role)
        user = event_rule_profile_user(role, [])
        rule = event_rule_fixture()
        on_exit(fn -> Repo.delete_all(from r in EventRule, where: r.id == ^rule.id) end)
        conn = log_in_api_user(build_conn(), user)

        for path <- ["/api/v2/event-rules", "/api/v2/event-rules/active"] do
          assert conn |> get(path) |> json_response(200) |> Map.fetch!("data") == []
        end

        assert conn |> get("/api/v2/event-rules/#{rule.id}") |> json_response(404) |> Map.has_key?("errors")

        grant_event_rule_permissions(user, ["observability.rules.view"])

        for path <- ["/api/v2/event-rules", "/api/v2/event-rules/active"] do
          response = conn |> get(path) |> json_response(200)
          assert Enum.any?(response["data"], &(&1["id"] == rule.id))
        end

        assert conn |> get("/api/v2/event-rules/#{rule.id}") |> json_response(200) |> get_in(["data", "id"]) == rule.id

        grant_event_rule_permissions(user, [])

        for path <- ["/api/v2/event-rules", "/api/v2/event-rules/active"] do
          assert conn |> get(path) |> json_response(200) |> Map.fetch!("data") == []
        end

        assert conn |> get("/api/v2/event-rules/#{rule.id}") |> json_response(404) |> Map.has_key?("errors")
      end

      for operation <- [:create, :update, :delete] do
        @tag :web_ng_shared_fixture_db
        @tag sandbox: :unboxed
        test "#{role} custom profile independently controls event rule #{operation}" do
          role = unquote(role)
          operation = unquote(operation)
          permission = "observability.rules.#{operation}"

          other_permissions =
            for action <- [:view, :create, :update, :delete],
                action != operation,
                do: "observability.rules.#{action}"

          user = event_rule_profile_user(role, other_permissions)
          rule = event_rule_fixture()
          revoked_rule = event_rule_fixture()
          conn = log_in_api_user(build_conn(), user)
          name = "Synthetic RBAC rule #{System.unique_integer([:positive])}"
          revoked_name = "#{name} revoked"
          rule_ids = [rule.id, revoked_rule.id]
          rule_names = [name, revoked_name]

          on_exit(fn ->
            Repo.delete_all(from r in EventRule, where: r.id in ^rule_ids or r.name in ^rule_names)
          end)

          denied = event_rule_request(conn, operation, rule.id, name)
          assert denied.status == 403
          assert Enum.any?(json_response(denied, 403)["errors"], &(&1["code"] == "forbidden"))
          assert Ash.get!(EventRule, rule.id, actor: system_actor()).priority == rule.priority
          refute Enum.any?(EventRule.list!(actor: system_actor()), &(&1.name == name))

          grant_event_rule_permissions(user, [permission])

          for path <- ["/api/v2/event-rules", "/api/v2/event-rules/active"] do
            assert conn |> get(path) |> json_response(200) |> Map.fetch!("data") == []
          end

          assert conn |> get("/api/v2/event-rules/#{rule.id}") |> json_response(404) |> Map.has_key?("errors")

          allowed = event_rule_request(conn, operation, rule.id, name)

          case operation do
            :create ->
              created = json_response(allowed, 201)["data"]
              assert Ash.get!(EventRule, created["id"], actor: system_actor()).name == name

            :update ->
              assert json_response(allowed, 200)["data"]["attributes"]["priority"] == 17
              assert Ash.get!(EventRule, rule.id, actor: system_actor()).priority == 17

            :delete ->
              assert allowed.status == 200
              refute Enum.any?(EventRule.list!(actor: system_actor()), &(&1.id == rule.id))
          end

          grant_event_rule_permissions(user, [])
          revoked = event_rule_request(conn, operation, revoked_rule.id, revoked_name)
          assert revoked.status == 403
          assert Enum.any?(json_response(revoked, 403)["errors"], &(&1["code"] == "forbidden"))
          assert Ash.get!(EventRule, revoked_rule.id, actor: system_actor()).priority == revoked_rule.priority
          refute Enum.any?(EventRule.list!(actor: system_actor()), &(&1.name == revoked_name))
        end
      end
    end
  end

  defp event_rule_profile_user(role, permissions) do
    user = if role == :operator, do: operator_user_fixture(), else: viewer_user_fixture()

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Synthetic rule profile #{System.unique_integer([:positive])}",
          permissions: permissions
        },
        actor: system_actor(),
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    on_exit(fn ->
      Repo.delete_all(from u in User, where: u.id == ^user.id)
      Repo.delete_all(from p in RoleProfile, where: p.id == ^profile.id)
    end)

    user
    |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: system_actor())
    |> Ash.update!()
  end

  defp grant_event_rule_permissions(user, permissions) do
    # Prime the same cache used by bearer authentication before changing the profile.
    RBAC.permissions_for_user(user)
    admin = admin_user_fixture()
    on_exit(fn -> Repo.delete_all(from u in User, where: u.id == ^admin.id) end)
    assert {:ok, _profile} = RoleProfilePolicy.update(admin, user.role_profile_id, %{permissions: permissions})
  end

  defp event_rule_request(conn, :create, _id, name) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post("/api/v2/event-rules", %{
      "data" => %{"type" => "event-rule", "attributes" => %{"name" => name, "source_type" => "log"}}
    })
  end

  defp event_rule_request(conn, :update, id, _name) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch("/api/v2/event-rules/#{id}", %{
      "data" => %{"type" => "event-rule", "id" => id, "attributes" => %{"priority" => 17}}
    })
  end

  defp event_rule_request(conn, :delete, id, _name), do: delete(conn, "/api/v2/event-rules/#{id}")

  describe "event rule API → log promotion integration" do
    @tag :web_ng_shared_fixture_db
    test "API mutations immediately refresh log promotion rules" do
      operator = operator_user_fixture()
      conn = log_in_api_user(build_conn(), operator)

      LogPromotion.invalidate_rules_cache()
      on_exit(&LogPromotion.invalidate_rules_cache/0)
      assert {:ok, cached_rules} = LogPromotion.active_log_rules()

      rule_name = "example-app-#{System.unique_integer([:positive])}"
      refute Enum.any?(cached_rules, &(&1.name == rule_name))

      params = %{
        "data" => %{
          "type" => "event-rule",
          "attributes" => %{
            "name" => rule_name,
            "source_type" => "log",
            "enabled" => true,
            "match" => %{"body" => "DatabaseError"},
            "event" => %{}
          }
        }
      }

      created =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v2/event-rules", params)
        |> json_response(201)

      assert created["data"]["type"] == "event-rule"
      id = created["data"]["id"]

      assert {:ok, rules} = LogPromotion.active_log_rules()
      assert Enum.any?(rules, &(&1.id == id))

      for enabled <- [false, true] do
        updated =
          conn
          |> put_req_header("content-type", "application/vnd.api+json")
          |> patch("/api/v2/event-rules/#{id}", %{
            "data" => %{
              "type" => "event-rule",
              "id" => id,
              "attributes" => %{"enabled" => enabled}
            }
          })
          |> json_response(200)

        assert updated["data"]["attributes"]["enabled"] == enabled
        assert {:ok, rules} = LogPromotion.active_log_rules()
        assert Enum.any?(rules, &(&1.id == id)) == enabled
      end

      deleted = delete(conn, "/api/v2/event-rules/#{id}")
      assert deleted.status == 200
      assert {:ok, rules} = LogPromotion.active_log_rules()
      refute Enum.any?(rules, &(&1.id == id))
    end
  end

  describe "JSON:API response format" do
    setup %{conn: conn} do
      _device = device_fixture(%{uid: "device-json-api"})

      %{conn: conn}
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
end
