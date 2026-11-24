defmodule ServiceRadarWebNGWeb.Api.HorizonProxyControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadar.Identity.RBAC.Catalog
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.HorizonProxy
  alias ServiceRadarWebNGWeb.Api.HorizonProxyController
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Router

  @endpoint ServiceRadarWebNGWeb.Endpoint
  @moduletag :db_free

  @secret_api_key "hrz_live_super_secret_proxy_key_do_not_leak"
  @upstream_base "https://api.horizon.serviceradar.cloud"

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _apps} = Application.ensure_all_started(:plug)
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    previous_loader = Application.get_env(:serviceradar_web_ng, :auth_settings_loader)
    Application.put_env(:serviceradar_web_ng, :auth_settings_loader, fn -> {:error, :not_configured} end)

    if is_nil(Process.whereis(ServiceRadar.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if is_nil(Process.whereis(ConfigCache)) do
      start_supervised!(ConfigCache)
    end

    if is_nil(Process.whereis(ServiceRadarWebNGWeb.Endpoint)) do
      start_supervised!(ServiceRadarWebNGWeb.Endpoint)
    end

    on_exit(fn ->
      restore_env(:auth_settings_loader, previous_loader)
    end)

    :ok
  end

  setup do
    prev_client = Application.get_env(:serviceradar_web_ng, :horizon_proxy_http_client)
    prev_resolver = Application.get_env(:serviceradar_web_ng, :horizon_proxy_upstream_resolver)
    prev_config = Application.get_env(:serviceradar_web_ng, :horizon_proxy)

    on_exit(fn ->
      restore_env(:horizon_proxy_http_client, prev_client)
      restore_env(:horizon_proxy_upstream_resolver, prev_resolver)
      restore_env(:horizon_proxy, prev_config)
    end)

    :ok
  end

  describe "authentication" do
    test "router rejects unauthenticated GET requests with 401" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/api/horizon/v1/bgp/watchlist")

      assert json_response(conn, 401) == %{"error" => "authentication_required"}
    end

    test "router rejects unauthenticated POST requests with 401" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer invalid.jwt.token")
        |> post("/api/horizon/v2/agents/enrollment-tokens", %{"label" => "branch-1"})

      assert conn.status == 401
    end

    test "controller rejects nil current_scope with 401" do
      conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist", nil)
      assert conn.status == 401
    end
  end

  describe "RBAC enforcement" do
    setup do
      stub_upstream({:ok, %{base_url: @upstream_base, api_key: @secret_api_key}})

      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{"content-type" => ["application/json"]},
           body: Jason.encode!(%{"items" => []})
         }}
      end)

      :ok
    end

    test "allows authenticated viewer on read-only GET routes" do
      conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist", scope_for_role(:viewer))

      assert json_response(conn, 200) == %{"items" => []}
      assert_receive {:upstream_request, req_opts}
      assert req_opts[:method] == :get
      assert req_opts[:url] == "#{@upstream_base}/api/v2/bgp/watchlist"
    end

    test "forbids viewer on POST mutating routes with 403" do
      conn =
        call_proxy(:post, "/api/horizon/v1/bgp/watchlist", scope_for_role(:viewer), %{
          "prefix" => "198.51.100.0/24"
        })

      assert conn.status == 403
      refute_received {:upstream_request, _}
    end

    test "forbids viewer on DELETE mutating routes with 403" do
      conn = call_proxy(:delete, "/api/horizon/v1/bgp/watchlist/wl-123", scope_for_role(:viewer))

      assert conn.status == 403
      refute_received {:upstream_request, _}
    end

    test "allows operator on POST mutating routes" do
      conn =
        call_proxy(:post, "/api/horizon/v2/agents/enrollment-tokens", scope_for_role(:operator), %{
          "label" => "branch-nyc"
        })

      assert json_response(conn, 200) == %{"items" => []}
      assert_receive {:upstream_request, req_opts}
      assert req_opts[:method] == :post
      assert req_opts[:url] == "#{@upstream_base}/api/v2/agents/enrollment-tokens"
    end
  end

  describe "strict path allowlist & traversal protection" do
    setup do
      stub_upstream({:ok, %{base_url: @upstream_base, api_key: @secret_api_key}})

      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})
        {:ok, %Req.Response{status: 200, headers: %{}, body: "{}"}}
      end)

      %{admin_scope: scope_for_role(:admin)}
    end

    test "rejects unlisted Horizon internal endpoints with 404", %{admin_scope: admin_scope} do
      conn = call_proxy(:post, "/api/horizon/v1/internal/operator/keys", admin_scope, %{})

      assert conn.status == 404
      refute_received {:upstream_request, _}
    end

    test "rejects path traversal segments with 404", %{admin_scope: admin_scope} do
      conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist/../../internal/operator/keys", admin_scope)

      assert conn.status == 404
      refute_received {:upstream_request, _}
    end

    test "rejects percent-encoded slash traversal with 404", %{admin_scope: admin_scope} do
      conn = call_proxy(:delete, "/api/horizon/v1/bgp/watchlist/..%2f..%2finternal", admin_scope)

      assert conn.status == 404
      refute_received {:upstream_request, _}
    end

    test "rejects disallowed HTTP method on read-only route with 404", %{admin_scope: admin_scope} do
      conn = call_proxy(:post, "/api/horizon/v1/feeds/status", admin_scope, %{})

      assert conn.status == 404
      refute_received {:upstream_request, _}
    end

    test "does not route or allowlist PUT and PATCH requests" do
      for method <- ["PUT", "PATCH"] do
        error =
          assert_raise Phoenix.Router.NoRouteError, fn ->
            method
            |> Plug.Test.conn("/api/horizon/v1/bgp/watchlist")
            |> Router.call(Router.init([]))
          end

        assert Plug.Exception.status(error) == 404

        assert {:error, :not_found} =
                 HorizonProxy.resolve_route(method, "v1", ["bgp", "watchlist"], "/api/horizon/v1/bgp/watchlist")
      end
    end

    test "rejects token query parameter with 400", %{admin_scope: admin_scope} do
      conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist?token=leaked", admin_scope)

      assert json_response(conn, 400) == %{"error" => "invalid_query"}
      refute_received {:upstream_request, _}
    end
  end

  describe "upstream configuration & SSRF validation" do
    test "returns 503 when Horizon is not configured" do
      stub_upstream({:error, :not_configured})

      conn = call_proxy(:get, "/api/horizon/v1/feeds/status", scope_for_role(:admin))

      assert json_response(conn, 503) == %{"error" => "horizon_not_configured"}
    end

    test "rejects http:// and link-local/metadata upstream URLs" do
      for bad_url <- [
            "http://api.horizon.serviceradar.cloud",
            "https://169.254.169.254",
            "https://127.0.0.1",
            "https://localhost",
            "https://[::1]",
            "https://[::ffff:169.254.169.254]",
            "https://metadata.google.internal"
          ] do
        assert {:error, :invalid_upstream_url} = HorizonProxy.validate_base_url(bad_url)
      end

      stub_upstream({:ok, %{base_url: "https://169.254.169.254", api_key: @secret_api_key}})

      conn = call_proxy(:get, "/api/horizon/v1/feeds/status", scope_for_role(:admin))

      assert json_response(conn, 502) == %{"error" => "horizon_upstream_invalid"}
      refute conn.resp_body =~ @secret_api_key
    end
  end

  describe "proxying allowlisted routes with server-side Bearer injection" do
    setup do
      stub_upstream({:ok, %{base_url: @upstream_base, api_key: @secret_api_key}})
      %{admin_scope: scope_for_role(:admin)}
    end

    test "proxies GET /api/horizon/v1/bgp/watchlist/events with query params to /api/v2/bgp/watchlist/events", %{
      admin_scope: admin_scope
    } do
      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{"content-type" => ["application/json; charset=utf-8"]},
           body: Jason.encode!(%{"events" => [%{"id" => "evt-1"}]})
         }}
      end)

      conn =
        call_proxy(
          :get,
          "/api/horizon/v1/bgp/watchlist/events?prefix=198.51.100.0%2F24&limit=25",
          admin_scope
        )

      assert json_response(conn, 200) == %{"events" => [%{"id" => "evt-1"}]}
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      refute conn.resp_body =~ @secret_api_key

      assert_receive {:upstream_request, req_opts}
      assert req_opts[:method] == :get
      assert req_opts[:url] == "#{@upstream_base}/api/v2/bgp/watchlist/events?prefix=198.51.100.0%2F24&limit=25"
      assert {"authorization", "Bearer #{@secret_api_key}"} in req_opts[:headers]
      assert req_opts[:redirect] == false
      assert req_opts[:retry] == false
      assert req_opts[:decode_body] == false
    end

    test "proxies POST /api/horizon/v1/bgp/watchlist to /api/v2/bgp/watchlist and preserves 201", %{
      admin_scope: admin_scope
    } do
      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 201,
           headers: %{"content-type" => ["application/json"]},
           body: Jason.encode!(%{"id" => "wl-1", "prefix" => "198.51.100.0/24"})
         }}
      end)

      conn = call_proxy(:post, "/api/horizon/v1/bgp/watchlist", admin_scope, %{"prefix" => "198.51.100.0/24"})

      assert json_response(conn, 201) == %{"id" => "wl-1", "prefix" => "198.51.100.0/24"}
      refute conn.resp_body =~ @secret_api_key

      assert_receive {:upstream_request, req_opts}
      assert req_opts[:method] == :post
      assert req_opts[:url] == "#{@upstream_base}/api/v2/bgp/watchlist"
      assert Jason.decode!(req_opts[:body]) == %{"prefix" => "198.51.100.0/24"}
      assert {"authorization", "Bearer #{@secret_api_key}"} in req_opts[:headers]
    end

    test "proxies POST /api/horizon/v2/agents/enrollment-tokens", %{admin_scope: admin_scope} do
      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 201,
           headers: %{"content-type" => ["application/json"]},
           body: Jason.encode!(%{"enrollment_token" => "hrz_enroll_abc"})
         }}
      end)

      conn = call_proxy(:post, "/api/horizon/v2/agents/enrollment-tokens", admin_scope, %{"ttl_secs" => 3600})

      assert json_response(conn, 201) == %{"enrollment_token" => "hrz_enroll_abc"}
      assert_receive {:upstream_request, req_opts}
      assert req_opts[:url] == "#{@upstream_base}/api/v2/agents/enrollment-tokens"
      assert {"authorization", "Bearer #{@secret_api_key}"} in req_opts[:headers]
    end

    test "proxies POST /api/horizon/v2/reports/isp-accountability and DELETE revoke", %{
      admin_scope: admin_scope
    } do
      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        case req_opts[:method] do
          :post ->
            {:ok,
             %Req.Response{
               status: 201,
               headers: %{"content-type" => ["application/json"]},
               body: Jason.encode!(%{"report_id" => "rep-42", "share_token" => "tok-99"})
             }}

          :delete ->
            {:ok, %Req.Response{status: 204, headers: %{}, body: ""}}
        end
      end)

      create_conn =
        call_proxy(:post, "/api/horizon/v2/reports/isp-accountability", admin_scope, %{
          "target_id" => "tgt-1",
          "window_start_unix_ms" => 1_700_000_000_000,
          "window_end_unix_ms" => 1_700_003_600_000
        })

      assert json_response(create_conn, 201) == %{"report_id" => "rep-42", "share_token" => "tok-99"}
      assert_receive {:upstream_request, create_req}
      assert create_req[:url] == "#{@upstream_base}/api/v2/reports/isp-accountability"

      delete_conn = call_proxy(:delete, "/api/horizon/v2/reports/isp-accountability/rep-42", admin_scope)

      assert response(delete_conn, 204) == ""
      assert_receive {:upstream_request, delete_req}
      assert delete_req[:method] == :delete
      assert delete_req[:url] == "#{@upstream_base}/api/v2/reports/isp-accountability/rep-42"
    end

    test "defaults non-JSON response content-type and normalizes nil body", %{admin_scope: admin_scope} do
      stub_http_client(fn _req_opts ->
        {:ok, %Req.Response{status: 200, headers: %{"content-type" => ["text/plain"]}, body: nil}}
      end)

      conn = call_proxy(:get, "/api/horizon/v1/feeds/status", admin_scope)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert conn.resp_body == ""
    end

    test "handles upstream timeout cleanly without leaking secrets", %{admin_scope: admin_scope} do
      stub_http_client(fn _req_opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      conn = call_proxy(:get, "/api/horizon/v1/weathermap/timeline", admin_scope)

      assert json_response(conn, 504) == %{"error" => "horizon_upstream_timeout"}
      refute conn.resp_body =~ @secret_api_key
    end
  end

  defp call_proxy(method, full_path, scope, body_params \\ nil) do
    uri = URI.parse(full_path)
    ["api", "horizon", version | path_segments] = String.split(uri.path, "/", trim: true)

    conn =
      method
      |> build_conn(full_path)
      |> put_req_header("accept", "application/json")
      |> Phoenix.Controller.accepts(["json"])
      |> assign(:current_scope, scope)
      |> Map.put(:params, %{"version" => version, "path" => path_segments})

    conn =
      if is_map(body_params) do
        Map.put(conn, :body_params, body_params)
      else
        conn
      end

    HorizonProxyController.call(conn, :proxy)
  end

  defp scope_for_role(role) do
    Scope.for_user(
      %{id: "00000000-0000-4000-8000-000000000001", email: "#{role}@example.com", role: role},
      permissions: Catalog.permissions_for_role(role)
    )
  end

  defp stub_upstream(result) do
    Application.put_env(:serviceradar_web_ng, :horizon_proxy_upstream_resolver, fn -> result end)
  end

  defp stub_http_client(fun) do
    Application.put_env(:serviceradar_web_ng, :horizon_proxy_http_client, fun)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
