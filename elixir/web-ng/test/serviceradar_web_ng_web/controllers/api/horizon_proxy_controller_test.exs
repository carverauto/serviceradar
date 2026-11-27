defmodule ServiceRadarWebNGWeb.Api.HorizonProxyControllerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn

  alias Phoenix.Router.NoRouteError
  alias ServiceRadar.Identity.RBAC.Catalog
  alias ServiceRadar.Security.RateLimiter
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
    {:ok, _apps} = Application.ensure_all_started(:req)
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    previous_loader = Application.get_env(:serviceradar_web_ng, :auth_settings_loader)
    Application.put_env(:serviceradar_web_ng, :auth_settings_loader, fn -> {:error, :not_configured} end)

    if is_nil(Process.whereis(ServiceRadar.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if is_nil(Process.whereis(ConfigCache)) do
      start_supervised!(ConfigCache)
    end

    if is_nil(Process.whereis(RateLimiter)) do
      start_supervised!(RateLimiter)
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
    clear_rate_limiter()

    on_exit(fn ->
      restore_env(:horizon_proxy_http_client, prev_client)
      restore_env(:horizon_proxy_upstream_resolver, prev_resolver)
      restore_env(:horizon_proxy, prev_config)
      Process.delete(:horizon_proxy_req_adapter)
      clear_rate_limiter()
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

    test "does not route PUT and rejects unallowlisted PATCH requests with 404", %{admin_scope: admin_scope} do
      error =
        assert_raise NoRouteError, fn ->
          "PUT"
          |> Plug.Test.conn("/api/horizon/v1/bgp/watchlist")
          |> Router.call(Router.init([]))
        end

      assert Plug.Exception.status(error) == 404

      assert {:error, :not_found} =
               HorizonProxy.resolve_route("PUT", "v1", ["bgp", "watchlist"], "/api/horizon/v1/bgp/watchlist")

      for path <- [
            "/api/horizon/v1/feeds/status",
            "/api/horizon/v1/bgp/watchlist",
            "/api/horizon/v1/alerts/rules/..%2f..%2finternal"
          ] do
        conn = dispatch_router(:patch, path, admin_scope, %{})
        assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
        refute_received {:upstream_request, _}
      end

      assert {:error, :not_found} =
               HorizonProxy.resolve_route("PATCH", "v1", ["bgp", "watchlist"], "/api/horizon/v1/bgp/watchlist")
    end

    test "rejects token query parameter with 400", %{admin_scope: admin_scope} do
      for query <- [
            "token=leaked",
            "TOKEN=leaked",
            "%74oken=leaked",
            "limit=10&token=leaked"
          ] do
        conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist?#{query}", admin_scope)

        assert json_response(conn, 400) == %{"error" => "invalid_query"}
        refute_received {:upstream_request, _}
      end
    end

    test "rejects malformed percent-encoded and invalid query strings with 400", %{admin_scope: admin_scope} do
      for bad_query <- [
            "foo=%ZZ",
            "foo=%2",
            "foo=%",
            "a=1&%ZZ=2",
            "foo=bar baz",
            "foo=bar#frag",
            "foo=bar\r\n"
          ] do
        assert {:error, :invalid_query} = HorizonProxy.validate_query_string(bad_query)
      end

      for valid_query <- [
            "prefix=198.51.100.0%2F24&limit=25",
            "q=hello+world",
            "next_page_token=abc"
          ] do
        assert {:ok, ^valid_query} = HorizonProxy.validate_query_string(valid_query)
      end

      conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist?foo=%ZZ", admin_scope)

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
            "https://metadata.google.internal",
            "https://localhost.",
            "https://localhost..",
            "https://localhost.localdomain.",
            "https://sub.localhost.",
            "https://metadata.google.internal.",
            "https://metadata.goog.",
            "https://instance-data.",
            "https://127.0.0.1.",
            "https://169.254.169.254.",
            "https://10.0.0.1.",
            "https://[::127.0.0.1]",
            "https://[::169.254.169.254]",
            "https://[::ffff:0:127.0.0.1]",
            "https://[::ffff:0:169.254.169.254]",
            "https://[64:ff9b::127.0.0.1]",
            "https://[64:ff9b::169.254.169.254]",
            "https://[2002:7f00:0001::1]",
            "https://[2002:a9fe:a9fe::1]",
            "https://[fe80::1%25eth0]",
            "https://api.horizon.example.com\r\nX-Injected: 1",
            "https://api.horizon.example.com\nX-Injected: 1",
            "https://api.horizon.example.com\0",
            "https://local%68ost",
            "https://%31%32%37.0.0.1"
          ] do
        assert HorizonProxy.validate_base_url(bad_url) == {:error, :invalid_upstream_url},
               "expected #{inspect(bad_url)} to be rejected"
      end

      for bad_url <- [
            "https://169.254.169.254",
            "https://metadata.google.internal.",
            "https://localhost.",
            "https://[::169.254.169.254]"
          ] do
        stub_upstream({:ok, %{base_url: bad_url, api_key: @secret_api_key}})
        assert {:error, :invalid_upstream_url} = HorizonProxy.resolve_upstream()
      end

      stub_upstream({:ok, %{base_url: "https://169.254.169.254", api_key: @secret_api_key}})

      conn = call_proxy(:get, "/api/horizon/v1/feeds/status", scope_for_role(:admin))

      assert json_response(conn, 502) == %{"error" => "horizon_upstream_invalid"}
      refute conn.resp_body =~ @secret_api_key
    end

    test "accepts and normalizes valid HTTPS upstream URLs" do
      assert {:ok, "https://api.horizon.example.com"} =
               HorizonProxy.validate_base_url("https://api.horizon.example.com/")

      assert {:ok, "https://api.horizon.example.com"} =
               HorizonProxy.validate_base_url("HTTPS://API.HORIZON.EXAMPLE.COM./")

      assert {:ok, "https://api.horizon.example.com:8443/v2"} =
               HorizonProxy.validate_base_url("https://api.horizon.example.com:8443/v2/")

      assert {:ok, "https://10.0.0.5"} =
               HorizonProxy.validate_base_url("https://10.0.0.5/")

      assert {:ok, "https://[fd00::1]"} =
               HorizonProxy.validate_base_url("https://[fd00::1]/")

      assert {:ok, "https://[2001:db8::1]:8443"} =
               HorizonProxy.validate_base_url("https://[2001:db8::1]:8443/")
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
      assert is_function(req_opts[:retry], 2)
      assert req_opts[:max_retries] == 2
      assert req_opts[:retry_delay].(0) == 50
      assert req_opts[:retry_log_level] == :debug
      assert req_opts[:decode_body] == false
      assert is_list(req_opts[:finch])
      refute Keyword.has_key?(req_opts, :connect_options)
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
      assert req_opts[:retry] == false
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
      assert delete_req[:retry] == false
    end

    test "proxies PATCH /api/horizon/v1/alerts/rules/:id with JSON body, RBAC, and retry: false", %{
      admin_scope: admin_scope
    } do
      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{"content-type" => ["application/json"]},
           body: Jason.encode!(%{"id" => "rule-1", "enabled" => false})
         }}
      end)

      viewer_conn =
        dispatch_router(:patch, "/api/horizon/v1/alerts/rules/rule-1", scope_for_role(:viewer), %{"enabled" => false})

      assert viewer_conn.status == 403
      refute_received {:upstream_request, _}

      operator_conn =
        dispatch_router(:patch, "/api/horizon/v1/alerts/rules/rule-1", scope_for_role(:operator), %{
          "enabled" => false
        })

      assert json_response(operator_conn, 200) == %{"id" => "rule-1", "enabled" => false}
      assert_receive {:upstream_request, req_opts}
      assert req_opts[:method] == :patch
      assert req_opts[:url] == "#{@upstream_base}/api/v1/alerts/rules/rule-1"
      assert {"content-type", "application/json"} in req_opts[:headers]
      assert {"authorization", "Bearer #{@secret_api_key}"} in req_opts[:headers]
      assert Jason.decode!(req_opts[:body]) == %{"enabled" => false}
      assert req_opts[:retry] == false

      admin_conn = dispatch_router(:patch, "/api/horizon/v1/alerts/rules/rule-1", admin_scope, %{"enabled" => true})
      assert json_response(admin_conn, 200) == %{"id" => "rule-1", "enabled" => false}
      assert_receive {:upstream_request, admin_req}
      assert admin_req[:method] == :patch
      assert Jason.decode!(admin_req[:body]) == %{"enabled" => true}

      empty_conn = call_proxy(:patch, "/api/horizon/v1/alerts/rules/rule-1", admin_scope)
      assert json_response(empty_conn, 200) == %{"id" => "rule-1", "enabled" => false}
      assert_receive {:upstream_request, empty_req}
      assert empty_req[:body] == "{}"
      assert {"content-type", "application/json"} in empty_req[:headers]
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

  describe "GET /api/horizon/v1/intel/lookup" do
    setup do
      stub_upstream({:ok, %{base_url: @upstream_base, api_key: @secret_api_key}})

      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{"content-type" => ["application/json"]},
           body: Jason.encode!(%{"asn" => 64_496, "org" => "Example Network"})
         }}
      end)

      :ok
    end

    test "rejects unauthenticated requests through the router with 401" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/api/horizon/v1/intel/lookup?asn=64496")

      assert json_response(conn, 401) == %{"error" => "authentication_required"}
      refute_received {:upstream_request, _}
    end

    test "proxies GET through the router for observability.events.view with query params and no-store headers" do
      events_only_scope = scope_with_permissions(:viewer, MapSet.new(["observability.events.view"]))

      conn =
        dispatch_router(
          :get,
          "/api/horizon/v1/intel/lookup?asn=64496&prefix=198.51.100.0%2F24&ip=198.51.100.1",
          events_only_scope
        )

      assert json_response(conn, 200) == %{"asn" => 64_496, "org" => "Example Network"}
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-ratelimit-limit") != []
      refute conn.resp_body =~ @secret_api_key

      assert_receive {:upstream_request, req_opts}
      assert req_opts[:method] == :get

      assert req_opts[:url] ==
               "#{@upstream_base}/api/v1/intel/lookup?asn=64496&prefix=198.51.100.0%2F24&ip=198.51.100.1"

      assert {"authorization", "Bearer #{@secret_api_key}"} in req_opts[:headers]
      assert {"accept", "application/json"} in req_opts[:headers]
      assert req_opts[:redirect] == false
      assert is_function(req_opts[:retry], 2)
      assert req_opts[:max_retries] == 2
      assert req_opts[:retry_delay].(0) == 50
      assert req_opts[:retry_log_level] == :debug
      assert req_opts[:decode_body] == false
      assert is_list(req_opts[:finch])
      refute Keyword.has_key?(req_opts, :connect_options)

      ipv6_conn =
        dispatch_router(
          :get,
          "/api/horizon/v1/intel/lookup?ip=2001:db8::1&prefix=2001:db8::%2F32",
          scope_for_role(:viewer)
        )

      assert json_response(ipv6_conn, 200) == %{"asn" => 64_496, "org" => "Example Network"}
      assert_receive {:upstream_request, ipv6_req}
      assert ipv6_req[:url] == "#{@upstream_base}/api/v1/intel/lookup?ip=2001:db8::1&prefix=2001:db8::%2F32"

      bare_conn = dispatch_router(:get, "/api/horizon/v1/intel/lookup", events_only_scope)
      assert json_response(bare_conn, 200) == %{"asn" => 64_496, "org" => "Example Network"}
      assert_receive {:upstream_request, bare_req}
      assert bare_req[:url] == "#{@upstream_base}/api/v1/intel/lookup"
    end

    test "forbids callers lacking observability.events.view even with sibling read permissions" do
      other_reads_scope =
        scope_with_permissions(:viewer, MapSet.new(["observability.traces.view", "devices.view"]))

      conn = dispatch_router(:get, "/api/horizon/v1/intel/lookup?asn=64496", other_reads_scope)

      assert conn.status == 403
      refute_received {:upstream_request, _}
    end

    test "rejects disallowed methods, versions, extra segments, and traversal on intel/lookup with 404" do
      admin_scope = scope_for_role(:admin)

      for {method, path, body} <- [
            {:post, "/api/horizon/v1/intel/lookup", %{}},
            {:patch, "/api/horizon/v1/intel/lookup", %{}},
            {:delete, "/api/horizon/v1/intel/lookup", nil},
            {:get, "/api/horizon/v2/intel/lookup?asn=64496", nil},
            {:get, "/api/horizon/v1/intel/lookup/extra", nil},
            {:get, "/api/horizon/v1/intel/lookup/..%2f..%2finternal", nil}
          ] do
        conn = dispatch_router(method, path, admin_scope, body)
        assert conn.status == 404, "expected 404 for #{method} #{path}"
        refute_received {:upstream_request, _}
      end

      error =
        assert_raise NoRouteError, fn ->
          "PUT"
          |> Plug.Test.conn("/api/horizon/v1/intel/lookup")
          |> Router.call(Router.init([]))
        end

      assert Plug.Exception.status(error) == 404

      for method <- ["PUT", "PATCH"] do
        assert {:error, :not_found} =
                 HorizonProxy.resolve_route(method, "v1", ["intel", "lookup"], "/api/horizon/v1/intel/lookup")
      end
    end

    test "rejects token smuggling and malformed query strings on intel/lookup with 400" do
      events_only_scope = scope_with_permissions(:viewer, MapSet.new(["observability.events.view"]))

      for bad_query <- ["token=leaked", "%74oken=leaked", "ip=%ZZ"] do
        conn = dispatch_router(:get, "/api/horizon/v1/intel/lookup?#{bad_query}", events_only_scope)
        assert json_response(conn, 400) == %{"error" => "invalid_query"}
        refute_received {:upstream_request, _}
      end
    end

    test "preserves upstream non-200 JSON responses with no-store headers without leaking secrets" do
      stub_http_client(fn _req_opts ->
        {:ok,
         %Req.Response{
           status: 404,
           headers: %{"content-type" => ["application/json"]},
           body: Jason.encode!(%{"error" => "intel_not_found"})
         }}
      end)

      conn = dispatch_router(:get, "/api/horizon/v1/intel/lookup?ip=198.51.100.99", scope_for_role(:viewer))

      assert json_response(conn, 404) == %{"error" => "intel_not_found"}
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      refute conn.resp_body =~ @secret_api_key
    end
  end

  describe "GET stale-connection retry policy" do
    setup do
      stub_upstream({:ok, %{base_url: @upstream_base, api_key: @secret_api_key}})
      %{admin_scope: scope_for_role(:admin)}
    end

    test "retries GET up to twice on stale transport and HTTP/2 close/GOAWAY errors", %{
      admin_scope: admin_scope
    } do
      for transient_error <- [
            %Req.TransportError{reason: :closed},
            %Req.TransportError{reason: :econnreset},
            %Req.TransportError{reason: :epipe},
            %Req.TransportError{reason: :etimedout},
            %Req.HTTPError{protocol: :http2, reason: :unprocessed},
            %Req.HTTPError{protocol: :http2, reason: :pool_not_available},
            %Req.HTTPError{protocol: :http2, reason: :connection_not_ready},
            %Req.HTTPError{protocol: :http2, reason: :closed},
            %Req.HTTPError{protocol: :http2, reason: :closed_for_writing},
            %Req.HTTPError{protocol: :http2, reason: {:server_closed_connection, :no_error}},
            %Req.HTTPError{protocol: :http2, reason: {:server_closed_request, :refused_stream}},
            %Req.HTTPError{protocol: :http2, reason: {:server_closed_connection, :no_error, ""}}
          ] do
        attempts = :counters.new(1, [])

        stub_req_adapter(fn req ->
          :counters.add(attempts, 1, 1)

          if :counters.get(attempts, 1) <= 2 do
            {req, transient_error}
          else
            {req,
             %Req.Response{
               status: 200,
               headers: %{"content-type" => ["application/json"]},
               body: Jason.encode!(%{"ok" => true})
             }}
          end
        end)

        warning_log =
          capture_log([level: :warning], fn ->
            conn = call_proxy(:get, "/api/horizon/v1/intel/lookup?asn=64496", admin_scope)
            assert json_response(conn, 200) == %{"ok" => true}
          end)

        assert :counters.get(attempts, 1) == 3
        assert warning_log == ""
      end
    end

    test "stops GET after two retries and returns 502 when stale connection persists", %{admin_scope: admin_scope} do
      attempts = :counters.new(1, [])

      stub_req_adapter(fn req ->
        :counters.add(attempts, 1, 1)
        {req, %Req.TransportError{reason: :closed}}
      end)

      conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist", admin_scope)

      assert json_response(conn, 502) == %{"error" => "horizon_upstream_unavailable"}
      assert :counters.get(attempts, 1) == 3
    end

    test "does not retry GET on timeout, econnrefused, HTTP/1 errors, or upstream 4xx/5xx responses", %{
      admin_scope: admin_scope
    } do
      timeout_attempts = :counters.new(1, [])

      stub_req_adapter(fn req ->
        :counters.add(timeout_attempts, 1, 1)
        {req, %Req.TransportError{reason: :timeout}}
      end)

      timeout_conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist", admin_scope)

      assert json_response(timeout_conn, 504) == %{"error" => "horizon_upstream_timeout"}
      assert :counters.get(timeout_attempts, 1) == 1

      for non_retryable_error <- [
            %Req.TransportError{reason: :econnrefused},
            %Req.HTTPError{protocol: :http1, reason: :unprocessed}
          ] do
        error_attempts = :counters.new(1, [])

        stub_req_adapter(fn req ->
          :counters.add(error_attempts, 1, 1)
          {req, non_retryable_error}
        end)

        error_conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist", admin_scope)

        assert json_response(error_conn, 502) == %{"error" => "horizon_upstream_unavailable"}
        assert :counters.get(error_attempts, 1) == 1
      end

      for status <- [408, 429, 500, 502, 503, 504] do
        status_attempts = :counters.new(1, [])

        stub_req_adapter(fn req ->
          :counters.add(status_attempts, 1, 1)

          {req,
           %Req.Response{
             status: status,
             headers: %{"content-type" => ["application/json"]},
             body: Jason.encode!(%{"error" => "upstream_#{status}"})
           }}
        end)

        status_conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist", admin_scope)

        assert json_response(status_conn, status) == %{"error" => "upstream_#{status}"}
        assert :counters.get(status_attempts, 1) == 1
      end
    end

    test "never retries POST, PATCH, or DELETE mutations even on closed, econnreset, or HTTP/2 unprocessed errors", %{
      admin_scope: admin_scope
    } do
      for stale_error <- [
            %Req.TransportError{reason: :closed},
            %Req.TransportError{reason: :econnreset},
            %Req.HTTPError{protocol: :http2, reason: :unprocessed}
          ] do
        post_attempts = :counters.new(1, [])

        stub_req_adapter(fn req ->
          :counters.add(post_attempts, 1, 1)
          {req, stale_error}
        end)

        post_conn =
          call_proxy(:post, "/api/horizon/v1/bgp/watchlist", admin_scope, %{"prefix" => "198.51.100.0/24"})

        assert json_response(post_conn, 502) == %{"error" => "horizon_upstream_unavailable"}
        assert :counters.get(post_attempts, 1) == 1

        patch_attempts = :counters.new(1, [])

        stub_req_adapter(fn req ->
          :counters.add(patch_attempts, 1, 1)
          {req, stale_error}
        end)

        patch_conn =
          call_proxy(:patch, "/api/horizon/v1/alerts/rules/rule-1", admin_scope, %{"enabled" => false})

        assert json_response(patch_conn, 502) == %{"error" => "horizon_upstream_unavailable"}
        assert :counters.get(patch_attempts, 1) == 1

        delete_attempts = :counters.new(1, [])

        stub_req_adapter(fn req ->
          :counters.add(delete_attempts, 1, 1)
          {req, stale_error}
        end)

        delete_conn = call_proxy(:delete, "/api/horizon/v1/bgp/watchlist/wl-123", admin_scope)

        assert json_response(delete_conn, 502) == %{"error" => "horizon_upstream_unavailable"}
        assert :counters.get(delete_attempts, 1) == 1
      end
    end

    test "recovers GET and refuses POST retry over a real Finch keep-alive pool when upstream closes or resets the socket" do
      Application.delete_env(:serviceradar_web_ng, :horizon_proxy_http_client)

      for close_mode <- [:fin, :rst] do
        {port, server_task} = start_stale_keepalive_upstream(close_mode)

        upstream = %{base_url: "http://127.0.0.1:#{port}", api_key: @secret_api_key}

        {:ok, get_route} =
          HorizonProxy.resolve_route("GET", "v1", ["vendor-status"], "/api/horizon/v1/vendor-status")

        # Request 1 warms a pooled HTTP/1.1 keep-alive connection in Req.Finch.
        assert {:ok, %{status: 200, body: warm_body}} =
                 HorizonProxy.forward(get_route, upstream, query_string: "category=cloud")

        assert Jason.decode!(warm_body) == %{"connection" => 1, "attempt" => "warm"}

        # Request 2 reuses the pooled socket, hits real :closed/:econnreset, and retries once on socket #2.
        warning_log =
          capture_log([level: :warning], fn ->
            assert {:ok, %{status: 200, body: recovered_body}} =
                     HorizonProxy.forward(get_route, upstream, query_string: "category=cloud")

            assert Jason.decode!(recovered_body) == %{"connection" => 2, "attempt" => "recovered"}
          end)

        assert warning_log == ""

        # Request 3 is a mutating POST on the pooled socket #2; server closes/resets it and must NOT see socket #3.
        {:ok, post_route} =
          HorizonProxy.resolve_route("POST", "v1", ["bgp", "watchlist"], "/api/horizon/v1/bgp/watchlist")

        assert {:error, :upstream_unavailable} =
                 HorizonProxy.forward(post_route, upstream, body: Jason.encode!(%{"prefix" => "198.51.100.0/24"}))

        summary = Task.await(server_task, 5_000)
        assert summary.connections == 2
        assert summary.requests == 4
        assert Enum.all?(summary.auth_headers, &(&1 == "Bearer #{@secret_api_key}"))
      end
    end

    test "uses HorizonFinch named pool without connect_options when started, and inline finch fallback otherwise", %{
      admin_scope: admin_scope
    } do
      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})
        {:ok, %Req.Response{status: 200, headers: %{"content-type" => ["application/json"]}, body: "{}"}}
      end)

      assert is_nil(Process.whereis(ServiceRadarWebNG.HorizonFinch))
      conn_fallback = call_proxy(:get, "/api/horizon/v1/outages", admin_scope)
      assert conn_fallback.status == 200
      assert_receive {:upstream_request, fallback_opts}
      refute Keyword.has_key?(fallback_opts, :connect_options)
      assert fallback_opts[:finch][:conn_max_idle_time] == 10_000
      assert fallback_opts[:finch][:http2][:ping_interval] == 15_000

      start_supervised!(
        {Finch,
         name: ServiceRadarWebNG.HorizonFinch,
         pools: %{
           default: [
             conn_opts: [transport_opts: [timeout: 5_000]],
             conn_max_idle_time: 10_000,
             http2: [
               ping_interval: 15_000,
               max_connection_age: 300_000,
               max_connection_age_jitter: 30_000
             ]
           ]
         }}
      )

      conn_named = call_proxy(:get, "/api/horizon/v1/outages", admin_scope)
      assert conn_named.status == 200
      assert_receive {:upstream_request, named_opts}
      refute Keyword.has_key?(named_opts, :connect_options)
      assert named_opts[:finch] == [name: ServiceRadarWebNG.HorizonFinch]
    end
  end

  describe "GET /api/horizon/v1/vendor-status and /api/horizon/v1/statuspages" do
    setup do
      stub_upstream({:ok, %{base_url: @upstream_base, api_key: @secret_api_key}})

      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{"content-type" => ["application/json"]},
           body: Jason.encode!(%{"vendors" => [%{"slug" => "example-cloud", "indicator" => "none"}]})
         }}
      end)

      :ok
    end

    test "rejects unauthenticated requests to vendor-status and statuspages through the router with 401" do
      for path <- ["/api/horizon/v1/vendor-status", "/api/horizon/v1/statuspages"] do
        conn =
          build_conn()
          |> put_req_header("accept", "application/json")
          |> get(path)

        assert json_response(conn, 401) == %{"error" => "authentication_required"}
        refute_received {:upstream_request, _}
      end
    end

    test "proxies GET vendor-status and statuspages through the router with observability.events.view" do
      events_only_scope = scope_with_permissions(:viewer, MapSet.new(["observability.events.view"]))

      for {proxy_path, expected_upstream_path} <- [
            {"/api/horizon/v1/vendor-status?category=identity_security&only_incidents=true",
             "/api/v1/vendor-status?category=identity_security&only_incidents=true"},
            {"/api/horizon/v1/vendor-status", "/api/v1/vendor-status"},
            {"/api/horizon/v1/statuspages?category=cloud", "/api/v1/statuspages?category=cloud"},
            {"/api/horizon/v1/statuspages", "/api/v1/statuspages"}
          ] do
        conn = dispatch_router(:get, proxy_path, events_only_scope)

        assert json_response(conn, 200) == %{
                 "vendors" => [%{"slug" => "example-cloud", "indicator" => "none"}]
               }

        assert get_resp_header(conn, "cache-control") == ["no-store"]
        refute conn.resp_body =~ @secret_api_key

        assert_receive {:upstream_request, req_opts}
        assert req_opts[:method] == :get
        assert req_opts[:url] == "#{@upstream_base}#{expected_upstream_path}"
        assert {"authorization", "Bearer #{@secret_api_key}"} in req_opts[:headers]
        assert is_function(req_opts[:retry], 2)
        assert req_opts[:max_retries] == 2
        assert req_opts[:retry_delay].(0) == 50
        assert req_opts[:retry_log_level] == :debug
      end
    end

    test "forbids callers lacking observability.events.view on vendor-status and statuspages" do
      other_reads_scope =
        scope_with_permissions(:viewer, MapSet.new(["observability.traces.view", "devices.view"]))

      for path <- ["/api/horizon/v1/vendor-status", "/api/horizon/v1/statuspages"] do
        conn = dispatch_router(:get, path, other_reads_scope)

        assert conn.status == 403
        refute_received {:upstream_request, _}
      end
    end

    test "rejects disallowed methods, versions, extra segments, and traversal on vendor-status and statuspages" do
      admin_scope = scope_for_role(:admin)

      for {method, path, body} <- [
            {:post, "/api/horizon/v1/vendor-status", %{}},
            {:patch, "/api/horizon/v1/vendor-status", %{}},
            {:delete, "/api/horizon/v1/vendor-status", nil},
            {:get, "/api/horizon/v2/vendor-status", nil},
            {:get, "/api/horizon/v1/vendor-status/extra", nil},
            {:get, "/api/horizon/v1/vendor-status/../feeds/status", nil},
            {:get, "/api/horizon/v1/vendor-status/..%2f..%2finternal", nil},
            {:post, "/api/horizon/v1/statuspages", %{}},
            {:patch, "/api/horizon/v1/statuspages", %{}},
            {:delete, "/api/horizon/v1/statuspages", nil},
            {:get, "/api/horizon/v2/statuspages", nil},
            {:get, "/api/horizon/v1/statuspages/extra", nil},
            {:get, "/api/horizon/v1/statuspages/../feeds/status", nil},
            {:get, "/api/horizon/v1/statuspages/..%2f..%2finternal", nil}
          ] do
        conn = dispatch_router(method, path, admin_scope, body)
        assert conn.status == 404, "expected 404 for #{method} #{path}"
        refute_received {:upstream_request, _}
      end

      for segment <- ["vendor-status", "statuspages"] do
        path = "/api/horizon/v1/#{segment}"

        error =
          assert_raise NoRouteError, fn ->
            "PUT"
            |> Plug.Test.conn(path)
            |> Router.call(Router.init([]))
          end

        assert Plug.Exception.status(error) == 404
        assert {:error, :not_found} = HorizonProxy.resolve_route("PUT", "v1", [segment], path)
        assert {:error, :not_found} = HorizonProxy.resolve_route("PATCH", "v1", [segment], path)
      end

      assert {:error, :not_found} =
               HorizonProxy.resolve_route("POST", "v1", ["vendor-status"], "/api/horizon/v1/vendor-status")

      assert {:error, :not_found} =
               HorizonProxy.resolve_route("POST", "v1", ["statuspages"], "/api/horizon/v1/statuspages")
    end

    test "rejects token smuggling and malformed query strings on vendor-status and statuspages with 400" do
      events_only_scope = scope_with_permissions(:viewer, MapSet.new(["observability.events.view"]))

      for path <- ["/api/horizon/v1/vendor-status", "/api/horizon/v1/statuspages"],
          bad_query <- ["token=leaked", "%74oken=leaked", "category=%ZZ"] do
        conn = dispatch_router(:get, "#{path}?#{bad_query}", events_only_scope)
        assert json_response(conn, 400) == %{"error" => "invalid_query"}
        refute_received {:upstream_request, _}
      end
    end
  end

  describe "Arrow IPC and non-JSON Accept / Content-Type pass-through" do
    setup do
      stub_upstream({:ok, %{base_url: @upstream_base, api_key: @secret_api_key}})
      %{viewer_scope: scope_for_role(:viewer), operator_scope: scope_for_role(:operator)}
    end

    test "forwards Arrow IPC Accept header through the router and preserves arbitrary binary bytes", %{
      viewer_scope: viewer_scope
    } do
      arrow_bytes = <<0xFF, 0xFF, 0xFF, 0xFF, 0x10, 0x00, 0x00, 0x00, "ARROW1", 0x00, 0x01, 0xFE, 0x80>>

      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{"content-type" => ["application/vnd.apache.arrow.stream"]},
           body: arrow_bytes
         }}
      end)

      for path <- ["/api/horizon/v1/outages", "/api/horizon/v1/weathermap"] do
        conn =
          dispatch_router(
            :get,
            "#{path}?format=arrow",
            viewer_scope,
            nil,
            "application/vnd.apache.arrow.stream"
          )

        assert conn.status == 200
        assert get_resp_header(conn, "content-type") == ["application/vnd.apache.arrow.stream"]
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert conn.resp_body == arrow_bytes

        assert_receive {:upstream_request, req_opts}
        assert {"accept", "application/vnd.apache.arrow.stream"} in req_opts[:headers]
      end
    end

    test "passes through arrow.file, octet-stream, gzip, csv, and ndjson media types intact", %{
      viewer_scope: viewer_scope,
      operator_scope: operator_scope
    } do
      gzip_bytes = <<0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xFF, 0xAB, 0xCD>>
      arrow_file_bytes = <<"ARROW1", 0x00, 0x00, 0xFF, 0xFE>>
      octet_bytes = <<0x00, 0x01, 0x02, 0xFE, 0xFF>>
      csv_body = "asn,loss_pct\n64496,0.25\n"
      ndjson_body = ~s({"id":"1"}\n{"id":"2"}\n)

      cases = [
        {"/api/horizon/v1/paths/dag", "application/vnd.apache.arrow.file", "application/vnd.apache.arrow.file",
         arrow_file_bytes},
        {"/api/horizon/v1/topology/snapshot", "application/octet-stream", "application/octet-stream", octet_bytes},
        {"/api/horizon/v1/feeds/reference/asns.ndjson.gz", "application/gzip", "application/gzip", gzip_bytes},
        {"/api/horizon/v1/public/reports/rep-99?format=csv", "text/csv", "text/csv; charset=utf-8", csv_body},
        {"/api/horizon/v1/outages", "application/x-ndjson", "application/x-ndjson", ndjson_body},
        {"/api/horizon/v1/outages", "application/ndjson", "application/ndjson", ndjson_body},
        {"/api/horizon/v1/outages", "application/problem+json", "application/problem+json", ~s({"title":"degraded"})},
        {"/api/horizon/v1/outages", "application/vnd.api+json", "application/vnd.api+json", ~s({"data":[]})},
        {"/api/horizon/v1/outages", "application/ld+json", "application/ld+json", ~s({"@context":{}})}
      ]

      for {path, req_accept, resp_ct, resp_body} <- cases do
        stub_http_client(fn req_opts ->
          send(self(), {:upstream_request, req_opts})
          {:ok, %Req.Response{status: 200, headers: %{"content-type" => [resp_ct]}, body: resp_body}}
        end)

        conn = dispatch_router(:get, path, viewer_scope, nil, req_accept)

        assert conn.status == 200
        assert get_resp_header(conn, "content-type") == [resp_ct]
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert conn.resp_body == resp_body

        assert_receive {:upstream_request, req_opts}
        assert {"accept", req_accept} in req_opts[:headers]
      end

      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})
        {:ok, %Req.Response{status: 204, headers: %{}, body: ""}}
      end)

      delete_conn =
        dispatch_router(
          :delete,
          "/api/horizon/v2/targets/tgt-1",
          operator_scope,
          nil,
          "application/vnd.apache.arrow.stream"
        )

      assert response(delete_conn, 204) == ""
      assert_receive {:upstream_request, delete_req}
      assert {"accept", "application/vnd.apache.arrow.stream"} in delete_req[:headers]
    end

    test "sanitizes unsafe response Content-Type and malformed client Accept headers", %{
      viewer_scope: viewer_scope
    } do
      for unsafe_ct <- [
            "text/html",
            "text/html; charset=utf-8",
            "image/svg+xml",
            "text/html+json",
            "application/xhtml+json",
            "application/javascript+json",
            "application/ecmascript+json",
            "application/json+evil",
            "application/text-html-json",
            "text/plain",
            "application/vnd.apache.arrow.stream\r\nX-Injected: 1"
          ] do
        stub_http_client(fn req_opts ->
          send(self(), {:upstream_request, req_opts})
          {:ok, %Req.Response{status: 200, headers: %{"content-type" => [unsafe_ct]}, body: "<svg/>"}}
        end)

        conn = dispatch_router(:get, "/api/horizon/v1/outages", viewer_scope)

        assert conn.status == 200
        assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
        assert_receive {:upstream_request, _req_opts}
      end

      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})
        {:ok, %Req.Response{status: 200, headers: %{"content-type" => ["application/json"]}, body: "{}"}}
      end)

      for bad_accept <- [
            nil,
            "",
            "   ",
            "application/json\r\nX-Injected: 1",
            "application/vnd.apache.arrow.stream\0",
            "not-a-media-type",
            "application/json; param=<script>"
          ] do
        conn = dispatch_router(:get, "/api/horizon/v1/outages", viewer_scope, nil, bad_accept)
        assert json_response(conn, 200) == %{}
        assert_receive {:upstream_request, req_opts}
        assert {"accept", "application/json"} in req_opts[:headers]
      end
    end

    test "renders JSON 401, 403, and 404 fallbacks when Arrow Accept header is sent", %{
      viewer_scope: viewer_scope
    } do
      unauth_conn =
        build_conn()
        |> put_req_header("accept", "application/vnd.apache.arrow.stream")
        |> get("/api/horizon/v1/outages")

      assert json_response(unauth_conn, 401) == %{"error" => "authentication_required"}

      forbidden_conn =
        dispatch_router(
          :get,
          "/api/horizon/v1/webhooks",
          viewer_scope,
          nil,
          "application/vnd.apache.arrow.stream"
        )

      assert json_response(forbidden_conn, 403) == %{"errors" => %{"detail" => "Forbidden"}}

      not_found_conn =
        dispatch_router(
          :get,
          "/api/horizon/v1/internal/operator/keys",
          viewer_scope,
          nil,
          "application/vnd.apache.arrow.stream"
        )

      assert json_response(not_found_conn, 404) == %{"errors" => %{"detail" => "Not Found"}}

      no_accept_404 = dispatch_router(:get, "/api/horizon/v1/internal/operator/keys", viewer_scope, nil, nil)
      assert json_response(no_accept_404, 404) == %{"errors" => %{"detail" => "Not Found"}}
    end
  end

  describe "Waves 1-4 allowlist and RBAC matrix" do
    setup do
      stub_upstream({:ok, %{base_url: @upstream_base, api_key: @secret_api_key}})

      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{"content-type" => ["application/json"]},
           body: "{}"
         }}
      end)

      %{viewer_scope: scope_for_role(:viewer), operator_scope: scope_for_role(:operator)}
    end

    test "allows viewer read routes across Waves 1-4 and rejects mutating methods on GET-only routes", %{
      viewer_scope: viewer_scope,
      operator_scope: operator_scope
    } do
      read_routes = [
        {"/api/horizon/v1/outages", "/api/v1/outages", true},
        {"/api/horizon/v1/outages/search?q=example", "/api/v1/outages/search?q=example", true},
        {"/api/horizon/v1/providers/health", "/api/v1/providers/health", true},
        {"/api/horizon/v1/weathermap", "/api/v1/weathermap", true},
        {"/api/horizon/v1/pops/map", "/api/v1/pops/map", true},
        {"/api/horizon/v1/topology/snapshot?ttl_secs=300", "/api/v1/topology/snapshot?ttl_secs=300", true},
        {"/api/horizon/v1/bgp/anomalies", "/api/v1/bgp/anomalies", true},
        {"/api/horizon/v1/feeds/sav", "/api/v1/feeds/sav", true},
        {"/api/horizon/v1/sav/findings", "/api/v1/sav/findings", false},
        {"/api/horizon/v1/sav/regressions", "/api/v1/sav/regressions", true},
        {"/api/horizon/v1/feeds/reference/manifest", "/api/v1/feeds/reference/manifest", true},
        {"/api/horizon/v1/feeds/reference/asns.ndjson.gz", "/api/v1/feeds/reference/asns.ndjson.gz", true},
        {"/api/horizon/v1/feeds/reference/prefixes.ndjson.gz", "/api/v1/feeds/reference/prefixes.ndjson.gz", true},
        {"/api/horizon/v1/public/bgp/zombies?asn=64496", "/api/v1/public/bgp/zombies?asn=64496", true},
        {"/api/horizon/v1/snapshots/shared/tok-abc-123", "/api/v1/snapshots/shared/tok-abc-123", true},
        {"/api/horizon/v1/public/reports/rep-abc-123", "/api/v1/public/reports/rep-abc-123", true},
        {"/api/horizon/v2/targets", "/api/v2/targets", false},
        {"/api/horizon/v2/targets/tgt-1/telemetry", "/api/v2/targets/tgt-1/telemetry", true},
        {"/api/horizon/v2/branch-allowlists", "/api/v2/branch-allowlists", false},
        {"/api/horizon/v1/alerts/rules", "/api/v1/alerts/rules", false},
        {"/api/horizon/v1/alerts/rules/rule-1", "/api/v1/alerts/rules/rule-1", false},
        {"/api/horizon/v1/alerts/events", "/api/v1/alerts/events", true},
        {"/api/horizon/v1/slos", "/api/v1/slos", false},
        {"/api/horizon/v1/slos/slo-1", "/api/v1/slos/slo-1", false},
        {"/api/horizon/v1/slos/slo-1/rollups", "/api/v1/slos/slo-1/rollups", true},
        {"/api/horizon/v1/slos/slo-1/burn-rate", "/api/v1/slos/slo-1/burn-rate", true},
        {"/api/horizon/v1/fusion/outages", "/api/v1/fusion/outages", true},
        {"/api/horizon/v1/fusion/bgp/anomalies", "/api/v1/fusion/bgp/anomalies", true}
      ]

      for {proxy_path, expected_upstream, get_only?} <- read_routes do
        conn = dispatch_router(:get, proxy_path, viewer_scope)
        assert conn.status == 200, "expected 200 for GET #{proxy_path}, got #{conn.status}"
        assert_receive {:upstream_request, req_opts}
        assert req_opts[:method] == :get
        assert req_opts[:url] == "#{@upstream_base}#{expected_upstream}"

        if get_only? do
          post_conn = dispatch_router(:post, proxy_path, operator_scope, %{})
          assert post_conn.status == 404, "expected 404 for POST #{proxy_path}"
          refute_received {:upstream_request, _}

          del_conn = dispatch_router(:delete, proxy_path, operator_scope)
          assert del_conn.status == 404, "expected 404 for DELETE #{proxy_path}"
          refute_received {:upstream_request, _}
        end
      end
    end

    test "enforces observability.traces.view on feeds/paths", %{viewer_scope: viewer_scope} do
      conn = dispatch_router(:get, "/api/horizon/v1/feeds/paths", viewer_scope)
      assert conn.status == 200
      assert_receive {:upstream_request, req_opts}
      assert req_opts[:url] == "#{@upstream_base}/api/v1/feeds/paths"

      events_only = scope_with_permissions(:viewer, MapSet.new(["observability.events.view"]))
      forbidden = dispatch_router(:get, "/api/horizon/v1/feeds/paths", events_only)
      assert forbidden.status == 403
      refute_received {:upstream_request, _}
    end

    test "enforces operator/write RBAC permissions on Waves 1-4 operator and mutating routes", %{
      viewer_scope: viewer_scope,
      operator_scope: operator_scope
    } do
      operator_routes = [
        {:post, "/api/horizon/v1/sav/findings", "/api/v1/sav/findings", %{"pop_id" => "pop-1"}},
        {:post, "/api/horizon/v2/targets", "/api/v2/targets", %{"host" => "198.51.100.10"}},
        {:post, "/api/horizon/v2/targets/verify-ownership", "/api/v2/targets/verify-ownership",
         %{"host_or_domain" => "example.com"}},
        {:delete, "/api/horizon/v2/targets/tgt-1", "/api/v2/targets/tgt-1", nil},
        {:post, "/api/horizon/v2/branch-allowlists", "/api/v2/branch-allowlists", %{"cidr" => "198.51.100.0/24"}},
        {:delete, "/api/horizon/v2/branch-allowlists?cidr=198.51.100.0%2F24",
         "/api/v2/branch-allowlists?cidr=198.51.100.0%2F24", nil},
        {:post, "/api/horizon/v2/pops/provision", "/api/v2/pops/provision", %{"pop_id" => "pop-1"}},
        {:post, "/api/horizon/v1/alerts/rules", "/api/v1/alerts/rules", %{"name" => "bgp-flap"}},
        {:patch, "/api/horizon/v1/alerts/rules/rule-1", "/api/v1/alerts/rules/rule-1", %{"enabled" => false}},
        {:delete, "/api/horizon/v1/alerts/rules/rule-1", "/api/v1/alerts/rules/rule-1", nil},
        {:post, "/api/horizon/v1/slos", "/api/v1/slos", %{"name" => "edge-slo"}},
        {:delete, "/api/horizon/v1/slos/slo-1", "/api/v1/slos/slo-1", nil},
        {:get, "/api/horizon/v1/webhooks", "/api/v1/webhooks", nil},
        {:get, "/api/horizon/v1/webhooks/wh-1/deliveries", "/api/v1/webhooks/wh-1/deliveries", nil},
        {:post, "/api/horizon/v1/webhooks", "/api/v1/webhooks", %{"url" => "https://hooks.example.com/1"}},
        {:delete, "/api/horizon/v1/webhooks/wh-1", "/api/v1/webhooks/wh-1", nil},
        {:post, "/api/horizon/v1/webhooks/wh-1/rebind", "/api/v1/webhooks/wh-1/rebind", %{"url" => "https://a.test"}},
        {:post, "/api/horizon/v1/webhooks/subscriptions", "/api/v1/webhooks/subscriptions",
         %{"target_url" => "https://hooks.example.com/sub"}},
        {:delete, "/api/horizon/v1/webhooks/subscriptions/sub-1", "/api/v1/webhooks/subscriptions/sub-1", nil},
        {:post, "/api/horizon/v1/fusion/impact-reports", "/api/v1/fusion/impact-reports", %{"summary" => "test"}}
      ]

      for {method, proxy_path, expected_upstream, body} <- operator_routes do
        denied = dispatch_router(method, proxy_path, viewer_scope, body)
        assert denied.status == 403, "expected 403 for viewer #{method} #{proxy_path}, got #{denied.status}"
        refute_received {:upstream_request, _}

        allowed = dispatch_router(method, proxy_path, operator_scope, body)
        assert allowed.status == 200, "expected 200 for operator #{method} #{proxy_path}, got #{allowed.status}"
        assert_receive {:upstream_request, req_opts}
        assert req_opts[:method] == method
        assert req_opts[:url] == "#{@upstream_base}#{expected_upstream}"
      end

      admin_scope = scope_for_role(:admin)

      for {method, proxy_path, expected_upstream, body} <- [
            {:get, "/api/horizon/v1/webhooks/wh-1/deliveries", "/api/v1/webhooks/wh-1/deliveries", nil},
            {:patch, "/api/horizon/v1/alerts/rules/rule-1", "/api/v1/alerts/rules/rule-1", %{"enabled" => false}}
          ] do
        admin_conn = dispatch_router(method, proxy_path, admin_scope, body)
        assert admin_conn.status == 200
        assert_receive {:upstream_request, req_opts}
        assert req_opts[:method] == method
        assert req_opts[:url] == "#{@upstream_base}#{expected_upstream}"
      end
    end

    test "prevents static segment shadowing and keeps internal/provisioning/stream/mcp routes unallowlisted", %{
      operator_scope: operator_scope
    } do
      blocked_routes = [
        {:delete, "/api/horizon/v2/targets/verify-ownership", nil},
        {:get, "/api/horizon/v2/targets/verify-ownership/telemetry", nil},
        {:get, "/api/horizon/v1/snapshots/shared", nil},
        {:delete, "/api/horizon/v1/snapshots/shared", nil},
        {:delete, "/api/horizon/v1/snapshots/shared/share", nil},
        {:delete, "/api/horizon/v1/webhooks/subscriptions", nil},
        {:post, "/api/horizon/v1/webhooks/subscriptions/rebind", %{}},
        {:get, "/api/horizon/v1/webhooks/subscriptions/deliveries", nil},
        {:post, "/api/horizon/v1/internal/operator/keys", %{}},
        {:post, "/api/horizon/v1/provisioning/accounts", %{}},
        {:post, "/api/horizon/v1/provisioning/accounts/acc-1/keys", %{}},
        {:delete, "/api/horizon/v1/provisioning/keys/key-1", nil},
        {:post, "/api/horizon/v1/retention", %{}},
        {:post, "/api/horizon/v1/agents/enroll", %{}},
        {:post, "/api/horizon/v1/feeds/checkpoints/ack", %{}},
        {:get, "/api/horizon/v2/stream/events", nil},
        {:get, "/api/horizon/v2/stream/ws", nil},
        {:post, "/api/horizon/v1/mcp", %{}}
      ]

      for {method, path, body} <- blocked_routes do
        conn = dispatch_router(method, path, operator_scope, body)
        assert conn.status == 404, "expected 404 for #{method} #{path}, got #{conn.status}"
        refute_received {:upstream_request, _}
      end
    end

    test "every HorizonProxy route permission exists in RBAC Catalog" do
      catalog_keys = MapSet.new(Catalog.permission_keys())

      sample_routes = [
        {"GET", "v1", ["outages"]},
        {"GET", "v1", ["feeds", "paths"]},
        {"GET", "v1", ["pops", "map"]},
        {"GET", "v1", ["alerts", "rules"]},
        {"POST", "v1", ["alerts", "rules"]},
        {"PATCH", "v1", ["alerts", "rules", "rule-1"]},
        {"DELETE", "v1", ["alerts", "rules", "rule-1"]}
      ]

      for {method, ver, segs} <- sample_routes do
        assert {:ok, %{required_permission: perm}} =
                 HorizonProxy.resolve_route(method, ver, segs, "/api/horizon/#{ver}/" <> Enum.join(segs, "/"))

        assert MapSet.member?(catalog_keys, perm), "expected #{perm} to exist in Catalog"
      end
    end
  end

  describe "cookie session CSRF enforcement on POST /api/horizon/v1/snapshots" do
    setup do
      stub_upstream({:ok, %{base_url: @upstream_base, api_key: @secret_api_key}})

      stub_http_client(fn req_opts ->
        send(self(), {:upstream_request, req_opts})

        {:ok,
         %Req.Response{
           status: 201,
           headers: %{"content-type" => ["application/json"]},
           body: Jason.encode!(%{"id" => "snap-123"})
         }}
      end)

      %{operator_scope: scope_for_role(:operator)}
    end

    test "returns 403 without x-csrf-token and 201 with valid CSRF token for cookie sessions", %{
      operator_scope: operator_scope
    } do
      Plug.CSRFProtection.delete_csrf_token()

      error =
        assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
          build_conn()
          |> init_test_session(%{})
          |> put_private(:plug_skip_csrf_protection, false)
          |> put_req_header("accept", "application/json")
          |> assign(:current_scope, operator_scope)
          |> post("/api/horizon/v1/snapshots", %{"title" => "Demo snapshot"})
        end

      assert Plug.Exception.status(error) == 403
      refute_received {:upstream_request, _}

      csrf_token = Plug.CSRFProtection.get_csrf_token()
      csrf_state = Plug.CSRFProtection.dump_state()

      allowed_conn =
        build_conn()
        |> init_test_session(%{"_csrf_token" => csrf_state})
        |> put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("accept", "application/json")
        |> put_req_header("x-csrf-token", csrf_token)
        |> assign(:current_scope, operator_scope)
        |> post("/api/horizon/v1/snapshots", %{"title" => "Demo snapshot"})

      assert allowed_conn.status == 201
      assert Jason.decode!(allowed_conn.resp_body) == %{"id" => "snap-123"}
      assert_receive {:upstream_request, req_opts}
      assert req_opts[:method] == :post
      assert req_opts[:url] == "#{@upstream_base}/api/v1/snapshots"
    end
  end

  def run(req) do
    adapter = Process.get(:horizon_proxy_req_adapter)
    adapter.(req)
  end

  defp start_stale_keepalive_upstream(close_mode) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen_socket)

    task =
      Task.async(fn ->
        try do
          # Connection 1: serve request #1 with keep-alive, then drop socket when request #2 arrives.
          {:ok, sock1} = :gen_tcp.accept(listen_socket, 5_000)
          req1 = read_http_request(sock1)
          send_http_json(sock1, 200, %{"connection" => 1, "attempt" => "warm"})

          req2 = read_http_request(sock1)
          close_socket(sock1, close_mode)

          # Connection 2: serve retried GET request #2 with keep-alive, then drop socket on POST request #3.
          {:ok, sock2} = :gen_tcp.accept(listen_socket, 5_000)
          req3 = read_http_request(sock2)
          send_http_json(sock2, 200, %{"connection" => 2, "attempt" => "recovered"})

          req4 = read_http_request(sock2)
          close_socket(sock2, close_mode)

          # Verify no third connection is dialed after the failed POST (wait briefly beyond 50ms retry delay).
          extra_connections =
            case :gen_tcp.accept(listen_socket, 150) do
              {:ok, sock3} ->
                :gen_tcp.close(sock3)
                1

              {:error, :timeout} ->
                0
            end

          %{
            connections: 2 + extra_connections,
            requests: 4,
            auth_headers: Enum.map([req1, req2, req3, req4], &extract_header(&1, "authorization"))
          }
        after
          :gen_tcp.close(listen_socket)
        end
      end)

    {port, task}
  end

  defp read_http_request(socket), do: read_http_request(socket, "")

  defp read_http_request(socket, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {pos, 4} ->
        headers_part = binary_part(acc, 0, pos)
        rest = binary_part(acc, pos + 4, byte_size(acc) - pos - 4)
        content_length = headers_part |> extract_header("content-length") |> parse_content_length()
        body = read_exact_bytes(socket, rest, content_length)
        headers_part <> "\r\n\r\n" <> body

      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        read_http_request(socket, acc <> chunk)
    end
  end

  defp read_exact_bytes(_socket, buf, needed) when byte_size(buf) >= needed, do: binary_part(buf, 0, needed)

  defp read_exact_bytes(socket, buf, needed) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
    read_exact_bytes(socket, buf <> chunk, needed)
  end

  defp parse_content_length(nil), do: 0

  defp parse_content_length(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> 0
    end
  end

  defp extract_header(raw_request, target_name) do
    target = String.downcase(target_name)

    raw_request
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == target, do: String.trim(value)

        _ ->
          nil
      end
    end)
  end

  defp send_http_json(socket, status, payload) do
    body = Jason.encode!(payload)

    response =
      "HTTP/1.1 #{status} OK\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: keep-alive\r\n\r\n" <>
        body

    :ok = :gen_tcp.send(socket, response)
  end

  defp close_socket(socket, :fin) do
    :gen_tcp.close(socket)
  end

  defp close_socket(socket, :rst) do
    _ = :inet.setopts(socket, [{:linger, {true, 0}}])
    :gen_tcp.close(socket)
  end

  defp stub_req_adapter(adapter) do
    Process.put(:horizon_proxy_req_adapter, adapter)

    stub_http_client(fn req_opts ->
      Req.request(Keyword.put(req_opts, :adapter, __MODULE__))
    end)
  end

  defp dispatch_router(method, full_path, scope, body_params \\ nil, accept \\ "application/json") do
    conn =
      build_conn()
      |> maybe_put_accept_header(accept)
      |> assign(:current_scope, scope)

    conn =
      if method in [:post, :patch, :delete] do
        put_req_header(conn, "authorization", "Bearer test-router-dispatch")
      else
        conn
      end

    case method do
      :get -> get(conn, full_path)
      :post -> post(conn, full_path, body_params || %{})
      :patch -> patch(conn, full_path, body_params || %{})
      :delete -> delete(conn, full_path)
    end
  end

  defp maybe_put_accept_header(conn, nil), do: conn
  defp maybe_put_accept_header(conn, accept), do: put_req_header(conn, "accept", accept)

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
    scope_with_permissions(role, Catalog.permissions_for_role(role))
  end

  defp scope_with_permissions(role, permissions) do
    Scope.for_user(
      %{
        id: "00000000-0000-4000-8000-000000000001",
        email: "#{role}@example.com",
        role: role,
        role_profile_id: nil
      },
      permissions: permissions
    )
  end

  defp clear_rate_limiter do
    table = RateLimiter.__table__()

    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end
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
