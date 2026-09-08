defmodule ServiceRadarWebNGWeb.Plugs.ConfineNarrowScopeTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [build_conn: 3]
  import Plug.Conn

  alias ServiceRadarWebNGWeb.Auth.NarrowScopes
  alias ServiceRadarWebNGWeb.Plugs.ConfineNarrowScope

  @moduletag :db_free

  describe "narrow-only tokens" do
    test "a plugin.publish token reaches the plugin publish routes" do
      for {method, path} <- [
            {"POST", "/api/admin/plugin-packages"},
            {"POST", "/api/admin/plugin-packages/#{Ecto.UUID.generate()}/upload-url"},
            {"GET", "/api/admin/plugin-packages/#{Ecto.UUID.generate()}"}
          ] do
        conn = run(method, path, "plugin.publish")

        refute conn.halted, "expected #{method} #{path} to pass for plugin.publish"
      end
    end

    test "a dashboard.publish token cannot stage a plugin package" do
      # The gap this plug closes: staging checks `plugins.stage` on the user and
      # never looked at what the token was granted for.
      conn = run("POST", "/api/admin/plugin-packages", "dashboard.publish")

      assert conn.halted
      assert conn.status == 403
      assert %{"error" => "insufficient_scope", "granted" => ["dashboard.publish"]} = decode(conn)
    end

    test "a plugin.publish token cannot publish a dashboard" do
      conn = run("POST", "/api/v1/dashboard-packages", "plugin.publish")

      assert conn.halted
      assert conn.status == 403
    end

    test "a plugins.manage token reaches assignment, credential, and controller routes" do
      id = Ecto.UUID.generate()

      for {method, path} <- [
            {"GET", "/api/admin/plugin-assignments"},
            {"POST", "/api/admin/plugin-assignments"},
            {"GET", "/api/admin/plugin-assignments/#{id}"},
            {"PATCH", "/api/admin/plugin-assignments/#{id}"},
            {"GET", "/api/admin/network-credential-rules"},
            {"POST", "/api/admin/network-credential-rules"},
            {"GET", "/api/admin/network-credential-secrets"},
            {"POST", "/api/admin/network-credential-secrets/#{id}/rotate"},
            {"POST", "/api/admin/network-credential-rules/#{id}/enable"},
            {"GET", "/api/admin/ansible-controllers"},
            {"POST", "/api/admin/ansible-controllers/#{id}/disable"},
            {"GET", "/api/admin/plugin-packages"},
            {"GET", "/api/admin/plugins"}
          ] do
        conn = run(method, path, "plugins.manage")

        refute conn.halted, "expected #{method} #{path} to pass for plugins.manage"
      end
    end

    test "a plugins.manage token cannot stage a plugin package" do
      conn = run("POST", "/api/admin/plugin-packages", "plugins.manage")

      assert conn.halted
      assert conn.status == 403
    end

    test "a plugin.publish token cannot create a credential rule" do
      conn = run("POST", "/api/admin/network-credential-rules", "plugin.publish")

      assert conn.halted
      assert conn.status == 403
    end

    test "a narrow token is refused on unrelated API routes" do
      for {method, path} <- [
            {"GET", "/api/admin/devices"},
            {"POST", "/api/admin/plugin-assignments"},
            {"POST", "/api/admin/plugin-packages/#{Ecto.UUID.generate()}/approve"},
            {"GET", "/api/admin/nats/credentials"}
          ] do
        conn = run(method, path, "plugin.publish")

        assert conn.halted, "expected #{method} #{path} to be refused for plugin.publish"
        assert conn.status == 403
      end
    end

    test "approving a package is not reachable with a publish scope" do
      # Publishing and approving are deliberately different privileges; a CLI
      # token must not be able to approve what it just staged.
      conn = run("POST", "/api/admin/plugin-packages/#{Ecto.UUID.generate()}/approve", "plugin.publish")

      assert conn.halted
      assert conn.status == 403
    end

    test "the path matcher is anchored so a nested segment cannot be reached" do
      conn = run("POST", "/api/admin/plugin-packages/x/upload-url/../approve", "plugin.publish")

      assert conn.halted
    end

    test "a token holding both narrow scopes reaches both surfaces" do
      assert run("POST", "/api/admin/plugin-packages", "dashboard.publish plugin.publish").halted == false
      assert run("POST", "/api/v1/dashboard-packages", "dashboard.publish plugin.publish").halted == false
    end
  end

  describe "callers this plug must not regress" do
    test "a request with no scope assign passes through" do
      # API keys, legacy static keys and browser sessions never set
      # :oauth_token_scope. They stay gated by RBAC in the controller.
      conn =
        "POST"
        |> build_conn("/api/admin/plugin-packages", nil)
        |> ConfineNarrowScope.call([])

      refute conn.halted
    end

    test "coarse client-credential scopes pass through untouched" do
      for scope <- NarrowScopes.coarse() do
        conn = run("POST", "/api/admin/plugin-packages", scope)

        refute conn.halted, "expected coarse scope #{scope} to pass"
      end
    end

    test "a coarse scope alongside a narrow one still passes" do
      refute run("GET", "/api/admin/devices", "read plugin.publish").halted
    end
  end

  describe "NarrowScopes.allowed?/3" do
    test "an empty scope set is allowed" do
      assert NarrowScopes.allowed?([], "POST", "/api/admin/plugin-packages")
    end

    test "an unknown narrow scope is allowed nowhere" do
      refute NarrowScopes.allowed?(["something.else"], "POST", "/api/admin/plugin-packages")
      refute NarrowScopes.allowed?(["something.else"], "GET", "/api/admin/devices")
    end

    test "method is part of the match" do
      assert NarrowScopes.allowed?(["plugin.publish"], "POST", "/api/admin/plugin-packages")
      refute NarrowScopes.allowed?(["plugin.publish"], "DELETE", "/api/admin/plugin-packages")
    end

    test "parse/1 splits a space-separated claim" do
      assert NarrowScopes.parse("a b  c") == ["a", "b", "c"]
      assert NarrowScopes.parse(nil) == []
      assert NarrowScopes.parse("") == []
    end

    test "every known narrow scope declares at least one route" do
      for scope <- NarrowScopes.known() do
        refute NarrowScopes.routes(scope) == [], "#{scope} allowlists nothing, so it grants nothing"
      end
    end
  end

  defp run(method, path, scope) do
    method
    |> build_conn(path, nil)
    |> assign(:oauth_token_scope, scope)
    |> ConfineNarrowScope.call([])
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)
end
