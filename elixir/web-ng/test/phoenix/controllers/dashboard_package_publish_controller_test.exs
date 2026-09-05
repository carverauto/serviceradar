defmodule ServiceRadarWebNGWeb.DashboardPackagePublishControllerTest do
  @moduledoc """
  DB-backed integration tests for the CLI dashboard-package publish API.

  Covers proposal `add-cli-dashboard-publish-api`:
  the publish/enable/disable endpoints, defense-in-depth scope + RBAC gating,
  the slug-ownership invariant, and the version-overwrite invariant.

  Run via the srql-fixtures CNPG instance per
  `.agents/skills/srql-fixtures-db-tests/SKILL.md`:

      SERVICERADAR_TEST_DATABASE_URL="postgres://..." \\
      SERVICERADAR_TEST_DATABASE_POOL_SIZE=1 \\
      SERVICERADAR_TEST_SANDBOX_MODE=shared \\
      MIX_ENV=test mix test test/phoenix/controllers/dashboard_package_publish_controller_test.exs
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Dashboards.Packages
  alias ServiceRadarWebNG.Plugins.Storage

  @moduletag :integration

  @renderer "export default {mount(){},destroy(){}}"
  @route "test-dashboard-#{System.unique_integer([:positive])}"

  setup do
    # Seed the new dashboards permissions onto the admin role profile in the
    # test DB so RBAC.can?(scope, "cli.dashboard.*") returns true. Production
    # picks these up via the RoleProfileSeeder; tests bypass that for speed.
    ensure_admin_has_dashboard_publish_permissions!()

    # Override blob storage to a tmp dir so the renderer write doesn't fail
    # against the production default `/var/lib/serviceradar/plugin-packages`.
    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    tmp = Path.join(System.tmp_dir!(), "sr-pub-test-#{System.unique_integer([:positive])}")

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :filesystem,
      base_path: tmp,
      signing_secret: "test-secret"
    )

    on_exit(fn ->
      RateLimiter.clear(:dashboard_publish, "*")
      RateLimiter.clear(:dashboard_publish_admin, "*")
      File.rm_rf(tmp)

      if original_storage do
        Application.put_env(:serviceradar_web_ng, :plugin_storage, original_storage)
      else
        Application.delete_env(:serviceradar_web_ng, :plugin_storage)
      end
    end)

    :ok
  end

  describe "POST /api/v1/dashboard-packages — happy paths" do
    test "publishes a fresh package with route slug and binds an instance", %{conn: conn} do
      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.pub.fresh", @renderer), @renderer, @route)

      body = json_response(conn, 200)
      assert body["dashboard_id"] == "com.test.pub.fresh"
      assert body["version"] == "0.1.0"
      assert body["route_slug"] == @route
      assert body["result"] == "written"
      assert body["content_hash"]
      assert binding_exists?(@route, "com.test.pub.fresh")
    end

    test "publishes without a route slug; no instance is created", %{conn: conn} do
      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.pub.no-route", @renderer), @renderer, nil)

      body = json_response(conn, 200)
      assert body["route_slug"] == nil
      assert body["result"] == "written"
    end

    test "idempotent re-publish with same bytes returns 200 + result: idempotent_noop",
         %{conn: conn} do
      manifest = manifest_for("com.test.pub.idempotent", @renderer)

      _ =
        publish_multipart(auth_cli(conn, :admin, ["dashboard.publish"]), manifest, @renderer, nil)

      conn2 =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest, @renderer, nil)

      body = json_response(conn2, 200)
      assert body["result"] == "idempotent_noop"
    end
  end

  describe "POST /api/v1/dashboard-packages — defense in depth" do
    test "JWT missing dashboard.publish scope is rejected with 403 insufficient_scope",
         %{conn: conn} do
      conn =
        conn
        |> auth_cli(:admin, ["read"])
        |> publish_multipart(manifest_for("com.test.scope", @renderer), @renderer, nil)

      body = json_response(conn, 403)
      assert body["error"] == "insufficient_scope"
      assert body["required"] == "dashboard.publish"
    end

    test "user without cli.dashboard.publish RBAC permission is rejected with 403 forbidden",
         %{conn: conn} do
      conn =
        conn
        |> auth_cli(:viewer, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.rbac", @renderer), @renderer, nil)

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
      assert body["permission"] == "cli.dashboard.publish"
    end

    test "no Authorization header is rejected with 401 by ApiAuth", %{conn: conn} do
      conn = publish_multipart(conn, manifest_for("com.test.noauth", @renderer), @renderer, nil)
      body = json_response(conn, 401)
      assert body["error"] == "unauthorized"
    end
  end

  describe "POST /api/v1/dashboard-packages — slug ownership" do
    test "409 slug_in_use when the slug is bound to a different dashboard_id", %{conn: conn} do
      slug = "owned-#{System.unique_integer([:positive])}"

      # Owner publishes + enables.
      _ =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.owner", @renderer), @renderer, slug)

      owner_pkg = published_package!("com.test.owner", "0.1.0")

      _ =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> post(~p"/api/v1/dashboard-packages/#{owner_pkg.id}/enable", %{"route" => slug})

      # Intruder tries the same slug under a different dashboard_id.
      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.intruder", @renderer), @renderer, slug)

      body = json_response(conn, 409)
      assert body["error"] == "slug_in_use"
      assert body["route"] == slug
      assert body["owner_dashboard_id"] == "com.test.owner"
    end

    test "same dashboard_id can re-publish to its own slug", %{conn: conn} do
      slug = "self-#{System.unique_integer([:positive])}"

      _ =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.self", @renderer), @renderer, slug)

      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.self", @renderer), @renderer, slug)

      body = json_response(conn, 200)
      assert body["result"] == "idempotent_noop"
      assert body["dashboard_id"] == "com.test.self"
    end
  end

  describe "POST /api/v1/dashboard-packages — version overwrite" do
    test "409 version_already_published when content differs and the row is verified",
         %{conn: conn} do
      manifest = manifest_for("com.test.ver.overwrite", @renderer)

      _ =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest, @renderer, nil)

      different_renderer = "export default {mount(){return 1},destroy(){}}"
      different_manifest = manifest_for("com.test.ver.overwrite", different_renderer)

      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(different_manifest, different_renderer, nil)

      body = json_response(conn, 409)
      assert body["error"] == "version_already_published"
      assert is_binary(body["existing_content_hash"])
    end
  end

  describe "POST /api/v1/dashboard-packages — multipart hardening" do
    test "manifest renderer.sha256 disagrees with bytes returns 422", %{conn: conn} do
      manifest = manifest_for("com.test.sha", @renderer)
      bad_manifest = put_in(manifest, ["renderer", "sha256"], String.duplicate("0", 64))

      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(bad_manifest, @renderer, nil)

      body = json_response(conn, 422)
      assert body["error"] == "unprocessable_renderer"
      assert body["reason"] == "sha256_mismatch"
    end

    test "invalid route slug returns 400 invalid_route", %{conn: conn} do
      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.slug", @renderer), @renderer, "Bad/Slug!")

      body = json_response(conn, 400)
      assert body["error"] == "invalid_route"
    end

    test "renderer larger than Storage.max_upload_bytes returns 413 payload_too_large",
         %{conn: conn} do
      # Override the byte cap to 4 KB so a small fixture trips the limit
      # without inflating CI runtimes. The controller reads max_upload_bytes
      # via Storage.max_upload_bytes/0 each request.
      previous = Application.get_env(:serviceradar_web_ng, :plugin_storage)
      cap_bytes = 4_096

      Application.put_env(
        :serviceradar_web_ng,
        :plugin_storage,
        Keyword.merge(previous || [], backend: :filesystem, max_upload_bytes: cap_bytes)
      )

      try do
        oversized = String.duplicate("x", cap_bytes + 1024)
        manifest = manifest_for("com.test.byte-cap.renderer", oversized)

        conn =
          conn
          |> auth_cli(:admin, ["dashboard.publish"])
          |> publish_multipart(manifest, oversized, nil)

        body = json_response(conn, 413)
        assert body["error"] == "payload_too_large"
        assert body["part"] == "renderer"
      after
        Application.put_env(:serviceradar_web_ng, :plugin_storage, previous || [])
      end
    end

    test "manifest larger than 256 KB returns 413 payload_too_large", %{conn: conn} do
      # The controller pins manifest part to <= 262_144 bytes. Pad the
      # description so the encoded JSON crosses that threshold; everything
      # else stays valid so we exercise the size check, not schema fail.
      padding = String.duplicate("a", 280_000)
      manifest = manifest_for("com.test.byte-cap.manifest", @renderer)
      bloated = Map.put(manifest, "description", padding)

      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(bloated, @renderer, nil)

      body = json_response(conn, 413)
      assert body["error"] == "payload_too_large"
      assert body["part"] == "manifest"
    end

    test "renderer with disallowed content-type returns 415", %{conn: conn} do
      manifest = manifest_for("com.test.byte-cap.ct", @renderer)
      manifest_path = write_tmp(Jason.encode!(manifest), "manifest.json")
      renderer_path = write_tmp(@renderer, "renderer.js")

      params = %{
        "manifest" => %Plug.Upload{
          path: manifest_path,
          filename: "manifest.json",
          content_type: "application/json"
        },
        "renderer" => %Plug.Upload{
          path: renderer_path,
          filename: "renderer.bin",
          content_type: "application/octet-stream"
        }
      }

      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> post(~p"/api/v1/dashboard-packages", params)

      body = json_response(conn, 415)
      assert body["error"] == "unsupported_media_type"
      assert body["part"] == "renderer"
    end

    test "missing manifest part returns 400 missing_part", %{conn: conn} do
      renderer_path = write_tmp(@renderer, "renderer.js")

      params = %{
        "renderer" => %Plug.Upload{
          path: renderer_path,
          filename: "renderer.js",
          content_type: "application/javascript"
        }
      }

      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> post(~p"/api/v1/dashboard-packages", params)

      body = json_response(conn, 400)
      assert body["error"] == "missing_part"
      assert body["part"] == "manifest"
    end
  end

  describe "POST /api/v1/dashboard-packages — rate limiting" do
    test "11th publish in 60 s on the same jti returns 429 with retry_after",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{role: :admin})

      {:ok, token, claims} =
        Guardian.create_api_token(user, scopes: [:"dashboard.publish"])

      jti = claims["jti"]

      # Seed the per-jti window with the limit so the next request trips it.
      Enum.each(1..10, fn _ ->
        RateLimiter.record(:dashboard_publish, "jti:#{jti}")
      end)

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> publish_multipart(manifest_for("com.test.rate", @renderer), @renderer, nil)

      body = json_response(conn, 429)
      assert body["error"] == "rate_limited"
      assert is_integer(body["retry_after"])
      assert ["" <> _] = Plug.Conn.get_resp_header(conn, "retry-after")

      RateLimiter.clear(:dashboard_publish, "jti:#{jti}")
    end
  end

  describe "POST /api/v1/dashboard-packages/:id/enable + /disable" do
    test "disable then re-enable round-trips status", %{conn: conn} do
      conn
      |> auth_cli(:admin, ["dashboard.publish"])
      |> publish_multipart(manifest_for("com.test.lifecycle", @renderer), @renderer, nil)

      package = published_package!("com.test.lifecycle", "0.1.0")

      enabled_resp =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> post(~p"/api/v1/dashboard-packages/#{package.id}/enable", %{})

      assert json_response(enabled_resp, 200)["status"] == "enabled"

      disabled_resp =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> post(~p"/api/v1/dashboard-packages/#{package.id}/disable", %{})

      assert json_response(disabled_resp, 200)["status"] == "disabled"
    end

    test "enable rejects 409 slug_in_use when binding to a foreign-owned slug",
         %{conn: conn} do
      slug = "guarded-#{System.unique_integer([:positive])}"

      # Owner publishes + enables on the slug.
      _ =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.guard.owner", @renderer), @renderer, slug)

      owner_pkg = published_package!("com.test.guard.owner", "0.1.0")

      _ =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> post(~p"/api/v1/dashboard-packages/#{owner_pkg.id}/enable", %{"route" => slug})

      # Different dashboard_id publishes (no slug), then tries to enable into the owner's slug.
      _ =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> publish_multipart(manifest_for("com.test.guard.intruder", @renderer), @renderer, nil)

      intruder_pkg = published_package!("com.test.guard.intruder", "0.1.0")

      conn =
        conn
        |> auth_cli(:admin, ["dashboard.publish"])
        |> post(~p"/api/v1/dashboard-packages/#{intruder_pkg.id}/enable", %{"route" => slug})

      body = json_response(conn, 409)
      assert body["error"] == "slug_in_use"
      assert body["route"] == slug
      assert body["owner_dashboard_id"] == "com.test.guard.owner"
    end
  end

  describe "Packages.import_json/3 (LiveView upload path) regression" do
    test "import_json/3 still returns {:ok, package} after publish/3 reroute" do
      manifest = Jason.encode!(manifest_for("com.test.lv.regression", @renderer))

      assert {:ok, %DashboardPackage{} = package} =
               Packages.import_json(
                 manifest,
                 @renderer,
                 actor: SystemActor.system(:test)
               )

      assert package.dashboard_id == "com.test.lv.regression"
      assert package.version == "0.1.0"
      assert is_binary(package.content_hash)
    end

    test "import_json/3 picks up the version-overwrite invariant" do
      manifest = Jason.encode!(manifest_for("com.test.lv.overwrite", @renderer))

      {:ok, _} =
        Packages.import_json(
          manifest,
          @renderer,
          actor: SystemActor.system(:test)
        )

      different = "export default {mount(){return 1},destroy(){}}"
      conflicting = Jason.encode!(manifest_for("com.test.lv.overwrite", different))

      assert {:error, {:version_already_published, info}} =
               Packages.import_json(
                 conflicting,
                 different,
                 actor: SystemActor.system(:test)
               )

      assert info[:dashboard_id] == "com.test.lv.overwrite"
    end
  end

  ## Helpers

  defp auth_cli(conn, :admin, scopes) do
    user = AccountsFixtures.user_fixture(%{role: :admin})

    {:ok, token, _claims} =
      Guardian.create_api_token(user, scopes: Enum.map(scopes, &String.to_atom/1))

    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp auth_cli(conn, :viewer, scopes) do
    user = AccountsFixtures.user_fixture(%{role: :viewer})

    {:ok, token, _claims} =
      Guardian.create_api_token(user, scopes: Enum.map(scopes, &String.to_atom/1))

    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp publish_multipart(conn, manifest, renderer_bytes, route_slug) do
    manifest_path = write_tmp(Jason.encode!(manifest), "manifest.json")
    renderer_path = write_tmp(renderer_bytes, "renderer.js")

    params = %{
      "manifest" => %Plug.Upload{
        path: manifest_path,
        filename: "manifest.json",
        content_type: "application/json"
      },
      "renderer" => %Plug.Upload{
        path: renderer_path,
        filename: "renderer.js",
        content_type: "application/javascript"
      }
    }

    params = if is_binary(route_slug), do: Map.put(params, "route", route_slug), else: params

    post(conn, ~p"/api/v1/dashboard-packages", params)
  end

  defp write_tmp(content, suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "sr-pub-#{System.unique_integer([:positive])}-#{suffix}"
      )

    File.write!(path, content)
    path
  end

  defp manifest_for(dashboard_id, renderer_bytes) do
    %{
      "schema_version" => 1,
      "id" => dashboard_id,
      "name" => "Test Dashboard",
      "version" => "0.1.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => Storage.sha256(renderer_bytes),
        "trust" => "trusted"
      },
      "data_frames" => [
        %{"id" => "f1", "query" => "in:wifi_sites limit:1", "encoding" => "json_rows"}
      ],
      "capabilities" => ["srql.execute"]
    }
  end

  defp published_package!(dashboard_id, version) do
    require Ash.Query

    actor = SystemActor.system(:test)

    {:ok, pkg} =
      DashboardPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(dashboard_id == ^dashboard_id and version == ^version)
      |> Ash.read_one(actor: actor)

    refute is_nil(pkg), "expected a DashboardPackage row for #{dashboard_id}@#{version}"
    pkg
  end

  defp binding_exists?(slug, dashboard_id) do
    require Ash.Query

    actor = SystemActor.system(:test)

    case DashboardInstance
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(route_slug == ^slug)
         |> Ash.Query.load(:dashboard_package)
         |> Ash.read_one(actor: actor) do
      {:ok, %DashboardInstance{dashboard_package: %{dashboard_id: ^dashboard_id}}} -> true
      _ -> false
    end
  end

  defp ensure_admin_has_dashboard_publish_permissions! do
    actor = SystemActor.system(:test)

    case RoleProfile.get_by_system_name("admin", actor: actor) do
      {:ok, %RoleProfile{} = profile} ->
        new_perms =
          profile.permissions
          |> MapSet.new()
          |> MapSet.union(
            MapSet.new([
              "cli.dashboard.publish",
              "cli.dashboard.enable",
              "cli.dashboard.disable"
            ])
          )
          |> MapSet.to_list()

        if length(new_perms) != length(profile.permissions) do
          {:ok, _} =
            RoleProfile.update_system_profile(
              profile,
              %{permissions: new_perms},
              actor: actor
            )

          # Bust the L2 cache so subsequent RBAC.can? sees the new permissions.
          if function_exported?(RBAC, :clear_process_cache, 0), do: RBAC.clear_process_cache()
        end

      _ ->
        :ok
    end
  end
end
