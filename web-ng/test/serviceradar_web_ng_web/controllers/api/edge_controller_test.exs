defmodule ServiceRadarWebNG.Api.EdgeControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Edge.OnboardingPackages

  # Use API bearer token authentication for /api/admin routes
  # (These routes use the :api_key_auth pipeline, not session auth)
  setup :register_and_log_in_api_user

  describe "GET /api/admin/edge-packages/defaults" do
    test "returns defaults", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/edge-packages/defaults")

      assert json_response(conn, 200)["selectors"] != nil
      assert json_response(conn, 200)["metadata"] != nil
    end
  end

  describe "GET /api/admin/edge-packages" do
    test "lists packages", %{conn: conn} do
      {:ok, _} = OnboardingPackages.create(%{label: "test-list-1"})
      {:ok, _} = OnboardingPackages.create(%{label: "test-list-2"})

      conn = get(conn, ~p"/api/admin/edge-packages")
      result = json_response(conn, 200)

      assert is_list(result)
      assert length(result) >= 2
    end

    test "filters by status", %{conn: conn} do
      {:ok, _} = OnboardingPackages.create(%{label: "test-filter-status"})

      conn = get(conn, ~p"/api/admin/edge-packages?status=issued")
      result = json_response(conn, 200)

      assert Enum.all?(result, &(&1["status"] == "issued"))
    end

    test "filters by component_type", %{conn: conn} do
      {:ok, _} = OnboardingPackages.create(%{label: "checker-1", component_type: "checker"})

      conn = get(conn, ~p"/api/admin/edge-packages?component_type=checker")
      result = json_response(conn, 200)

      assert Enum.all?(result, &(&1["component_type"] == "checker"))
    end

    test "respects limit", %{conn: conn} do
      for i <- 1..5 do
        OnboardingPackages.create(%{label: "limit-test-#{i}"})
      end

      conn = get(conn, ~p"/api/admin/edge-packages?limit=2")
      result = json_response(conn, 200)

      assert length(result) == 2
    end
  end

  describe "POST /api/admin/edge-packages" do
    test "creates a package", %{conn: conn} do
      params = %{
        "label" => "new-poller",
        "component_type" => "poller",
        "site" => "datacenter-1"
      }

      conn = post(conn, ~p"/api/admin/edge-packages", params)
      result = json_response(conn, 201)

      assert result["package"]["package_id"] != nil
      assert result["package"]["label"] == "new-poller"
      assert result["package"]["component_type"] == "poller"
      assert result["package"]["site"] == "datacenter-1"
      assert result["package"]["status"] == "issued"
      assert result["join_token"] != nil
      assert result["download_token"] != nil
    end

    test "creates a checker package", %{conn: conn} do
      params = %{
        "label" => "sysmon-checker",
        "component_type" => "checker",
        "checker_kind" => "sysmon",
        "security_mode" => "mtls"
      }

      conn = post(conn, ~p"/api/admin/edge-packages", params)
      result = json_response(conn, 201)

      assert result["package"]["component_type"] == "checker"
      assert result["package"]["checker_kind"] == "sysmon"
      assert result["package"]["security_mode"] == "mtls"
    end

    test "returns 422 for missing label", %{conn: conn} do
      params = %{"component_type" => "poller"}

      conn = post(conn, ~p"/api/admin/edge-packages", params)

      assert json_response(conn, 422)["error"] == "validation_error"
    end
  end

  describe "GET /api/admin/edge-packages/:id" do
    test "returns a package", %{conn: conn} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-show"})

      conn = get(conn, ~p"/api/admin/edge-packages/#{created.package.id}")
      result = json_response(conn, 200)

      assert result["package_id"] == created.package.id
      assert result["label"] == "test-show"
    end

    test "returns 404 for non-existent package", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/api/admin/edge-packages/#{fake_id}")

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/admin/edge-packages/:id" do
    test "soft-deletes a package", %{conn: conn} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-delete"})

      conn = delete(conn, ~p"/api/admin/edge-packages/#{created.package.id}")

      assert response(conn, 204)

      # Verify it's deleted
      {:ok, package} = OnboardingPackages.get(created.package.id)
      assert package.status == :deleted
    end

    test "returns 404 for non-existent package", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn = delete(conn, ~p"/api/admin/edge-packages/#{fake_id}")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/admin/edge-packages/:id/events" do
    test "lists events for a package", %{conn: conn} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-events"})

      # Wait for async event to be recorded (or use sync in test)
      Process.sleep(100)

      conn = get(conn, ~p"/api/admin/edge-packages/#{created.package.id}/events")
      result = json_response(conn, 200)

      assert is_list(result)
    end

    test "returns 404 for non-existent package", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/api/admin/edge-packages/#{fake_id}/events")

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/admin/edge-packages/:id/revoke" do
    test "revokes a package", %{conn: conn} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-revoke"})

      conn =
        post(conn, ~p"/api/admin/edge-packages/#{created.package.id}/revoke", %{
          "reason" => "no longer needed"
        })

      result = json_response(conn, 200)
      assert result["status"] == "revoked"
    end

    test "returns 409 for already revoked package", %{conn: conn} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-revoke-twice"})
      OnboardingPackages.revoke(created.package.id)

      conn = post(conn, ~p"/api/admin/edge-packages/#{created.package.id}/revoke", %{})

      assert json_response(conn, 409)["error"] == "package already revoked"
    end
  end

  describe "POST /api/admin/edge-packages/:id/download (unauthenticated)" do
    test "allows download with valid token" do
      {:ok, created} = OnboardingPackages.create(%{label: "test-download"})

      # Use unauthenticated connection
      conn = build_conn()

      conn =
        post(conn, ~p"/api/admin/edge-packages/#{created.package.id}/download", %{
          "download_token" => created.download_token
        })

      result = json_response(conn, 200)
      assert result["package"]["status"] == "delivered"
      assert result["join_token"] != nil
    end

    test "returns 401 for invalid token" do
      {:ok, created} = OnboardingPackages.create(%{label: "test-invalid-token"})

      conn = build_conn()

      conn =
        post(conn, ~p"/api/admin/edge-packages/#{created.package.id}/download", %{
          "download_token" => "wrong-token"
        })

      assert json_response(conn, 401)["error"] == "download token invalid"
    end

    test "returns 400 for missing token" do
      {:ok, created} = OnboardingPackages.create(%{label: "test-missing-token"})

      conn = build_conn()
      conn = post(conn, ~p"/api/admin/edge-packages/#{created.package.id}/download", %{})

      assert json_response(conn, 400)["error"] == "download_token is required"
    end

    test "returns 409 for already delivered package" do
      {:ok, created} = OnboardingPackages.create(%{label: "test-double-deliver"})

      # First delivery
      conn = build_conn()

      post(conn, ~p"/api/admin/edge-packages/#{created.package.id}/download", %{
        "download_token" => created.download_token
      })

      # Second attempt
      conn = build_conn()

      conn =
        post(conn, ~p"/api/admin/edge-packages/#{created.package.id}/download", %{
          "download_token" => created.download_token
        })

      assert json_response(conn, 409)["error"] == "package already_delivered"
    end
  end

  describe "GET /api/admin/component-templates" do
    test "returns templates list", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/component-templates")
      result = json_response(conn, 200)

      assert is_list(result)
    end
  end
end
