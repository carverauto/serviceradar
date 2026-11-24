defmodule ServiceRadarWebNGWeb.Api.HorizonProxyControllerTest do
  use ExUnit.Case, async: false

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

    test "does not route or allowlist PUT and PATCH requests" do
      for method <- ["PUT", "PATCH"] do
        error =
          assert_raise NoRouteError, fn ->
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
      assert req_opts[:max_retries] == 1
      assert req_opts[:retry_delay].(0) == 50
      assert req_opts[:retry_log_level] == :debug
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
      assert req_opts[:max_retries] == 1
      assert req_opts[:retry_delay].(0) == 50
      assert req_opts[:retry_log_level] == :debug
      assert req_opts[:decode_body] == false

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
            {:delete, "/api/horizon/v1/intel/lookup", nil},
            {:get, "/api/horizon/v2/intel/lookup?asn=64496", nil},
            {:get, "/api/horizon/v1/intel/lookup/extra", nil},
            {:get, "/api/horizon/v1/intel/lookup/..%2f..%2finternal", nil}
          ] do
        conn = dispatch_router(method, path, admin_scope, body)
        assert conn.status == 404, "expected 404 for #{method} #{path}"
        refute_received {:upstream_request, _}
      end

      for method <- ["PUT", "PATCH"] do
        error =
          assert_raise NoRouteError, fn ->
            method
            |> Plug.Test.conn("/api/horizon/v1/intel/lookup")
            |> Router.call(Router.init([]))
          end

        assert Plug.Exception.status(error) == 404

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

    test "retries GET once on closed, econnreset, and HTTP/2 unprocessed errors", %{admin_scope: admin_scope} do
      for transient_error <- [
            %Req.TransportError{reason: :closed},
            %Req.TransportError{reason: :econnreset},
            %Req.HTTPError{protocol: :http2, reason: :unprocessed}
          ] do
        attempts = :counters.new(1, [])

        stub_req_adapter(fn req ->
          :counters.add(attempts, 1, 1)

          if :counters.get(attempts, 1) == 1 do
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

        conn = call_proxy(:get, "/api/horizon/v1/intel/lookup?asn=64496", admin_scope)

        assert json_response(conn, 200) == %{"ok" => true}
        assert :counters.get(attempts, 1) == 2
      end
    end

    test "stops GET after one retry and returns 502 when stale connection persists", %{admin_scope: admin_scope} do
      attempts = :counters.new(1, [])

      stub_req_adapter(fn req ->
        :counters.add(attempts, 1, 1)
        {req, %Req.TransportError{reason: :closed}}
      end)

      conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist", admin_scope)

      assert json_response(conn, 502) == %{"error" => "horizon_upstream_unavailable"}
      assert :counters.get(attempts, 1) == 2
    end

    test "does not retry GET on timeout or upstream 5xx responses", %{admin_scope: admin_scope} do
      timeout_attempts = :counters.new(1, [])

      stub_req_adapter(fn req ->
        :counters.add(timeout_attempts, 1, 1)
        {req, %Req.TransportError{reason: :timeout}}
      end)

      timeout_conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist", admin_scope)

      assert json_response(timeout_conn, 504) == %{"error" => "horizon_upstream_timeout"}
      assert :counters.get(timeout_attempts, 1) == 1

      status_attempts = :counters.new(1, [])

      stub_req_adapter(fn req ->
        :counters.add(status_attempts, 1, 1)

        {req,
         %Req.Response{
           status: 503,
           headers: %{"content-type" => ["application/json"]},
           body: Jason.encode!(%{"error" => "upstream_maintenance"})
         }}
      end)

      status_conn = call_proxy(:get, "/api/horizon/v1/bgp/watchlist", admin_scope)

      assert json_response(status_conn, 503) == %{"error" => "upstream_maintenance"}
      assert :counters.get(status_attempts, 1) == 1
    end

    test "never retries POST or DELETE mutations even on closed connections", %{admin_scope: admin_scope} do
      post_attempts = :counters.new(1, [])

      stub_req_adapter(fn req ->
        :counters.add(post_attempts, 1, 1)
        {req, %Req.TransportError{reason: :closed}}
      end)

      post_conn =
        call_proxy(:post, "/api/horizon/v1/bgp/watchlist", admin_scope, %{"prefix" => "198.51.100.0/24"})

      assert json_response(post_conn, 502) == %{"error" => "horizon_upstream_unavailable"}
      assert :counters.get(post_attempts, 1) == 1

      delete_attempts = :counters.new(1, [])

      stub_req_adapter(fn req ->
        :counters.add(delete_attempts, 1, 1)
        {req, %Req.TransportError{reason: :closed}}
      end)

      delete_conn = call_proxy(:delete, "/api/horizon/v1/bgp/watchlist/wl-123", admin_scope)

      assert json_response(delete_conn, 502) == %{"error" => "horizon_upstream_unavailable"}
      assert :counters.get(delete_attempts, 1) == 1
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
            {:delete, "/api/horizon/v1/vendor-status", nil},
            {:get, "/api/horizon/v2/vendor-status", nil},
            {:get, "/api/horizon/v1/vendor-status/extra", nil},
            {:get, "/api/horizon/v1/vendor-status/..%2f..%2finternal", nil},
            {:post, "/api/horizon/v1/statuspages", %{}},
            {:delete, "/api/horizon/v1/statuspages", nil},
            {:get, "/api/horizon/v2/statuspages", nil},
            {:get, "/api/horizon/v1/statuspages/extra", nil},
            {:get, "/api/horizon/v1/statuspages/..%2f..%2finternal", nil}
          ] do
        conn = dispatch_router(method, path, admin_scope, body)
        assert conn.status == 404, "expected 404 for #{method} #{path}"
        refute_received {:upstream_request, _}
      end

      assert {:error, :not_found} =
               HorizonProxy.resolve_route("POST", "v1", ["vendor-status"], "/api/horizon/v1/vendor-status")

      assert {:error, :not_found} =
               HorizonProxy.resolve_route("POST", "v1", ["statuspages"], "/api/horizon/v1/statuspages")
    end
  end

  def run(req) do
    adapter = Process.get(:horizon_proxy_req_adapter)
    adapter.(req)
  end

  defp stub_req_adapter(adapter) do
    Process.put(:horizon_proxy_req_adapter, adapter)

    stub_http_client(fn req_opts ->
      Req.request(Keyword.put(req_opts, :adapter, __MODULE__))
    end)
  end

  defp dispatch_router(method, full_path, scope, body_params \\ nil) do
    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> assign(:current_scope, scope)

    conn =
      if method in [:post, :delete] do
        put_req_header(conn, "authorization", "Bearer test-router-dispatch")
      else
        conn
      end

    case method do
      :get -> get(conn, full_path)
      :post -> post(conn, full_path, body_params || %{})
      :delete -> delete(conn, full_path)
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
