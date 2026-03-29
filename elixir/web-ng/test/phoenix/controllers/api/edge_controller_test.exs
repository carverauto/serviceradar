defmodule ServiceRadarWebNGWeb.Api.EdgeControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, actor_for_user: 1, user_fixture: 0, system_actor: 0]

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Edge.OnboardingPackages

  setup %{conn: conn} do
    user = admin_user_fixture()
    scope = Scope.for_user(user)
    actor = actor_for_user(user)

    {:ok, token, _claims} = Guardian.create_access_token(user)

    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn, user: user, scope: scope, actor: actor}
  end

  describe "GET /api/admin/edge-packages/defaults" do
    test "returns defaults", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/edge-packages/defaults")

      assert json_response(conn, 200)["selectors"]
      assert json_response(conn, 200)["metadata"]
    end
  end

  describe "API auth hardening" do
    test "rejects reset tokens for API auth", %{conn: _conn, user: user} do
      {:ok, reset_token, _claims} = Guardian.create_access_token(user, token_type: "reset")

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{reset_token}")
        |> get(~p"/api/admin/edge-packages/defaults")

      assert conn.status == 401
    end

    test "rejects authenticated users without settings.edge.manage", %{conn: _conn} do
      viewer = user_fixture()

      # Ensure a low-permission role, regardless of fixture defaults.
      _ =
        viewer
        |> Ash.Changeset.for_update(:update_role, %{role: :viewer}, actor: system_actor())
        |> Ash.update!()

      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/admin/edge-packages/defaults")

      assert conn.status == 403
    end
  end

  describe "GET /api/admin/edge-packages" do
    test "lists packages", %{conn: conn, actor: actor} do
      {:ok, _} = OnboardingPackages.create(%{label: "test-list-1"}, actor: actor)
      {:ok, _} = OnboardingPackages.create(%{label: "test-list-2"}, actor: actor)

      conn = get(conn, ~p"/api/admin/edge-packages")
      result = json_response(conn, 200)

      assert is_list(result)
      assert length(result) >= 2
    end

    test "filters by status", %{conn: conn, actor: actor} do
      {:ok, _} =
        OnboardingPackages.create(%{label: "test-filter-status"}, actor: actor)

      conn = get(conn, ~p"/api/admin/edge-packages?status=issued")
      result = json_response(conn, 200)

      assert Enum.all?(result, &(&1["status"] == "issued"))
    end

    test "filters by component_type", %{conn: conn, actor: actor} do
      {:ok, _} =
        OnboardingPackages.create(%{label: "checker-1", component_type: "checker"}, actor: actor)

      conn = get(conn, ~p"/api/admin/edge-packages?component_type=checker")
      result = json_response(conn, 200)

      assert Enum.all?(result, &(&1["component_type"] == "checker"))
    end

    test "respects limit", %{conn: conn, actor: actor} do
      for i <- 1..5 do
        OnboardingPackages.create(%{label: "limit-test-#{i}"}, actor: actor)
      end

      conn = get(conn, ~p"/api/admin/edge-packages?limit=2")
      result = json_response(conn, 200)

      assert length(result) == 2
    end
  end

  describe "POST /api/admin/edge-packages" do
    test "creates a package", %{conn: conn} do
      params = %{
        "label" => "new-gateway",
        "component_type" => "gateway",
        "site" => "datacenter-1"
      }

      conn = post(conn, ~p"/api/admin/edge-packages", params)
      result = json_response(conn, 201)

      assert result["package"]["package_id"]
      assert result["package"]["label"] == "new-gateway"
      assert result["package"]["component_type"] == "gateway"
      assert result["package"]["site"] == "datacenter-1"
      assert result["package"]["status"] == "issued"
      assert result["join_token"]
      assert result["download_token"]
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
      params = %{"component_type" => "gateway"}

      conn = post(conn, ~p"/api/admin/edge-packages", params)

      assert json_response(conn, 422)["error"] == "validation_error"
    end
  end

  describe "GET /api/admin/edge-packages/:id" do
    test "returns a package", %{conn: conn, actor: actor} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-show"}, actor: actor)

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
    test "soft-deletes a package", %{conn: conn, actor: actor} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-delete"}, actor: actor)

      conn = delete(conn, ~p"/api/admin/edge-packages/#{created.package.id}")

      assert response(conn, 204)

      # Verify it's deleted
      {:ok, package} = OnboardingPackages.get(created.package.id, actor: actor)
      assert package.status == :deleted
    end

    test "returns 404 for non-existent package", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn = delete(conn, ~p"/api/admin/edge-packages/#{fake_id}")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/admin/edge-packages/:id/events" do
    test "lists events for a package", %{conn: conn, actor: actor} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-events"}, actor: actor)

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
    test "revokes a package", %{conn: conn, actor: actor} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-revoke"}, actor: actor)

      conn =
        post(conn, ~p"/api/admin/edge-packages/#{created.package.id}/revoke", %{
          "reason" => "no longer needed"
        })

      result = json_response(conn, 200)
      assert result["status"] == "revoked"
    end

    test "returns 409 for already revoked package", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-revoke-twice"}, actor: actor)

      OnboardingPackages.revoke(created.package.id, actor: actor)

      conn = post(conn, ~p"/api/admin/edge-packages/#{created.package.id}/revoke", %{})

      assert json_response(conn, 409)["error"] == "package already revoked"
    end
  end

  describe "POST /api/admin/edge-packages/:id/download (unauthenticated)" do
    test "allows download with valid token", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-download"}, actor: actor)

      # Use unauthenticated connection
      conn =
        post(build_conn(), ~p"/api/admin/edge-packages/#{created.package.id}/download", %{
          "download_token" => created.download_token
        })

      result = json_response(conn, 200)
      assert result["package"]["status"] == "delivered"
      assert result["join_token"]
    end

    test "returns 401 for invalid token", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-invalid-token"}, actor: actor)

      conn =
        post(build_conn(), ~p"/api/admin/edge-packages/#{created.package.id}/download", %{
          "download_token" => "wrong-token"
        })

      assert json_response(conn, 401)["error"] == "download token invalid"
    end

    test "returns 400 for missing token", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-missing-token"}, actor: actor)

      conn = post(build_conn(), ~p"/api/admin/edge-packages/#{created.package.id}/download", %{})

      assert json_response(conn, 400)["error"] == "download_token is required"
    end

    test "returns 409 for already delivered package", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-double-deliver"}, actor: actor)

      # First delivery
      post(build_conn(), ~p"/api/admin/edge-packages/#{created.package.id}/download", %{
        "download_token" => created.download_token
      })

      # Second attempt
      conn =
        post(build_conn(), ~p"/api/admin/edge-packages/#{created.package.id}/download", %{
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

  describe "POST /api/edge-packages/:id/bundle" do
    test "downloads bundle with valid token", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-bundle-download"}, actor: actor)

      # Use unauthenticated connection (public endpoint)
      conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", created.download_token)
        |> post(~p"/api/edge-packages/#{created.package.id}/bundle", %{})

      assert response_content_type(conn, :gzip) =~ "application/gzip"
      assert response(conn, 200) != ""

      # Verify it's a valid gzip tarball
      body = response(conn, 200)
      assert {:ok, _files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])
    end

    test "returns 400 without token", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-no-token"}, actor: actor)

      conn = post(build_conn(), ~p"/api/edge-packages/#{created.package.id}/bundle", %{})

      assert json_response(conn, 400)["error"] == "download token is required"
    end

    test "returns 401 for invalid token", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-bad-token"}, actor: actor)

      conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", "wrong-token")
        |> post(~p"/api/edge-packages/#{created.package.id}/bundle", %{})

      assert json_response(conn, 401)["error"] == "download token invalid"
    end

    test "returns 404 for non-existent package", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", "some-token")
        |> post(~p"/api/edge-packages/#{fake_id}/bundle", %{})

      assert json_response(conn, 404)["error"] == "package not found"
    end

    test "returns 409 for already delivered package", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-double-bundle"}, actor: actor)

      # First download
      build_conn()
      |> put_req_header("x-serviceradar-download-token", created.download_token)
      |> post(~p"/api/edge-packages/#{created.package.id}/bundle", %{})

      # Second attempt
      conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", created.download_token)
        |> post(~p"/api/edge-packages/#{created.package.id}/bundle", %{})

      assert json_response(conn, 409)["error"] == "package already_delivered"
    end

    test "bundle contains expected files", %{conn: conn, actor: actor} do
      {:ok, created} =
        OnboardingPackages.create(
          %{
            label: "test-bundle-contents",
            component_type: :checker,
            checker_kind: "sysmon"
          },
          actor: actor
        )

      conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", created.download_token)
        |> post(~p"/api/edge-packages/#{created.package.id}/bundle", %{})

      body = response(conn, 200)
      {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

      file_names = Enum.map(files, fn {name, _} -> to_string(name) end)

      # Verify all expected files
      assert Enum.any?(file_names, &String.ends_with?(&1, "component.pem"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "component-key.pem"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "ca-chain.pem"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "config.yaml"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "install.sh"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "README.md"))
    end
  end

  describe "full onboarding flow integration" do
    test "complete flow: create -> download bundle -> package delivered", %{conn: conn} do
      # Step 1: Create package via API
      params = %{
        "label" => "integration-test-gateway",
        "component_type" => "gateway",
        "site" => "test-site"
      }

      conn = post(conn, ~p"/api/admin/edge-packages", params)
      create_result = json_response(conn, 201)

      package_id = create_result["package"]["package_id"]
      download_token = create_result["download_token"]

      assert create_result["package"]["status"] == "issued"
      assert download_token

      # Step 2: Download bundle (unauthenticated, using token)
      bundle_conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", download_token)
        |> post(~p"/api/edge-packages/#{package_id}/bundle", %{})

      assert response(bundle_conn, 200) != ""

      # Step 3: Verify package is now delivered
      verify_conn =
        conn
        |> recycle()
        |> put_req_header("authorization", conn |> get_req_header("authorization") |> List.first())

      verify_conn = get(verify_conn, ~p"/api/admin/edge-packages/#{package_id}")
      show_result = json_response(verify_conn, 200)

      assert show_result["status"] == "delivered"
      assert show_result["delivered_at"]
    end
  end
end
