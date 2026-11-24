defmodule ServiceRadarWebNGWeb.McpHorizonProtocolTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Mcp
  alias ServiceRadarWebNG.Mcp.OAuth
  alias ServiceRadarWebNG.Mcp.OAuth.Pkce
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @moduletag :db_free

  @client_id "serviceradar-mcp"
  @antigravity_callback "https://antigravity.google/oauth-callback"
  @upstream_base "https://api.horizon.serviceradar.cloud"
  @secret_api_key "hrz_live_mcp_protocol_secret_do_not_leak"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:plug)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)

    prev_auth_loader = Application.get_env(:serviceradar_web_ng, :auth_settings_loader)
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

    endpoint_server =
      start_supervised!(
        {Bandit, plug: ServiceRadarWebNGWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: :live_endpoint_bandit
      )

    mcp_server =
      start_supervised!(
        {Bandit, plug: __MODULE__.McpTestPlug, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: :live_mcp_bandit
      )

    {:ok, {{127, 0, 0, 1}, endpoint_port}} = ThousandIsland.listener_info(endpoint_server)
    {:ok, {{127, 0, 0, 1}, mcp_port}} = ThousandIsland.listener_info(mcp_server)

    on_exit(fn -> restore_web_env(:auth_settings_loader, prev_auth_loader) end)

    %{
      endpoint_url: "http://127.0.0.1:#{endpoint_port}",
      mcp_url: "http://127.0.0.1:#{mcp_port}"
    }
  end

  setup do
    prev_mcp = Application.get_env(:serviceradar_web_ng, :mcp_enabled)
    prev_catalog = Application.get_env(:serviceradar_web_ng, :srql_catalog)
    prev_srql = Application.get_env(:serviceradar_web_ng, :srql_module)
    prev_client = Application.get_env(:serviceradar_web_ng, :horizon_proxy_http_client)
    prev_resolver = Application.get_env(:serviceradar_web_ng, :horizon_proxy_upstream_resolver)
    prev_starrocks = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(:serviceradar_web_ng, :mcp_enabled, true)
    Application.put_env(:serviceradar_web_ng, :srql_catalog, fn _scope -> Catalog.structured() end)
    Application.put_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
    clear_rate_limiter()

    on_exit(fn ->
      restore_web_env(:mcp_enabled, prev_mcp)
      restore_web_env(:srql_catalog, prev_catalog)
      restore_web_env(:srql_module, prev_srql)
      restore_web_env(:horizon_proxy_http_client, prev_client)
      restore_web_env(:horizon_proxy_upstream_resolver, prev_resolver)
      Application.put_env(:serviceradar_core, StarRocks, prev_starrocks)
      clear_rate_limiter()
    end)

    %{prev_starrocks: prev_starrocks}
  end

  describe "live HTTP OAuth authorize and discovery on ServiceRadarWebNGWeb.Endpoint" do
    test "serves OAuth discovery metadata and challenges unauthenticated /mcp", %{endpoint_url: base_url} do
      pr = Req.get!(base_url <> "/.well-known/oauth-protected-resource", retry: false)
      assert pr.status == 200
      assert pr.body["resource"] =~ "/mcp"
      assert "mcp" in pr.body["scopes_supported"]

      as_meta = Req.get!(base_url <> "/.well-known/oauth-authorization-server", retry: false)
      assert as_meta.status == 200
      assert as_meta.body["authorization_endpoint"] =~ "/oauth/authorize"
      assert as_meta.body["code_challenge_methods_supported"] == ["S256"]

      unauth =
        Req.post!(base_url <> "/mcp",
          json: rpc("initialize", initialize_params()),
          headers: [{"accept", "application/json"}],
          retry: false
        )

      assert unauth.status == 401
      [www_auth | _] = Map.get(unauth.headers, "www-authenticate", [])
      assert www_auth =~ "/.well-known/oauth-protected-resource"
    end

    test "accepts exact Antigravity HTTPS callback and RFC 8252 loopback URIs on /oauth/authorize", %{
      endpoint_url: base_url
    } do
      challenge = Pkce.challenge_s256(OAuth.random_token())

      for allowed_uri <- [
            @antigravity_callback,
            "http://127.0.0.1:43721/callback",
            "http://localhost:8080/oauth",
            "http://[::1]:9/"
          ] do
        clear_rate_limiter()

        resp =
          Req.get!(base_url <> "/oauth/authorize",
            params: authorize_params(challenge, allowed_uri),
            redirect: false,
            retry: false
          )

        assert resp.status == 302, "expected 302 for #{allowed_uri}, got #{resp.status}"
        assert Map.get(resp.headers, "location") == ["/users/log-in"]
        assert Enum.any?(Map.get(resp.headers, "set-cookie", []), &(&1 =~ "_serviceradar_web_ng_key="))
      end

      clear_rate_limiter()

      missing_pkce =
        Req.get!(base_url <> "/oauth/authorize",
          params:
            challenge
            |> authorize_params(@antigravity_callback)
            |> Map.delete("code_challenge_method"),
          redirect: false,
          retry: false
        )

      assert missing_pkce.status == 302
      [location] = Map.get(missing_pkce.headers, "location")
      assert String.starts_with?(location, @antigravity_callback <> "?")
      assert location =~ "error=invalid_request"
      assert location =~ "state=state-proto-1"
    end

    test "rejects spoofed and mutated HTTPS callback URIs on /oauth/authorize with 400 and no redirect", %{
      endpoint_url: base_url
    } do
      challenge = Pkce.challenge_s256(OAuth.random_token())

      for rejected_uri <- [
            "https://evil.example/oauth-callback",
            "https://antigravity.google.evil.com/oauth-callback",
            "https://sub.antigravity.google/oauth-callback",
            "https://antigravity.google/other",
            "https://antigravity.google/oauth-callback/extra",
            "https://antigravity.google/oauth-callback?foo=bar",
            "https://antigravity.google/oauth-callback#frag",
            "https://user@antigravity.google/oauth-callback",
            "https://antigravity.google:8443/oauth-callback",
            "http://antigravity.google/oauth-callback",
            "https://antigravity.google/oauth-callback/../other"
          ] do
        clear_rate_limiter()

        resp =
          Req.get!(base_url <> "/oauth/authorize",
            params: authorize_params(challenge, rejected_uri),
            redirect: false,
            retry: false
          )

        assert resp.status == 400, "expected 400 for #{rejected_uri}, got #{resp.status}"
        assert resp.body["error"] == "invalid_request"
        refute Map.has_key?(resp.headers, "location")
      end
    end
  end

  describe "live HTTP JSON-RPC MCP protocol over AshAi.Mcp.Router" do
    test "exposes horizon_intel_lookup schema and Horizon resources over MCP JSON-RPC", %{mcp_url: mcp_url} do
      perms = ["settings.mcp.manage", "observability.events.view", "observability.traces.view"]

      init = post_mcp!(mcp_url, perms, rpc("initialize", initialize_params()))
      assert init.status == 200
      assert init.body["result"]["serverInfo"]["name"] == "serviceradar"
      assert init.body["result"]["instructions"] =~ "horizon_intel_lookup"

      tools_resp = post_mcp!(mcp_url, perms, rpc("tools/list"))
      tools = tools_resp.body["result"]["tools"]
      expected_names = Mcp.v1_tools() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
      assert tools |> Enum.map(& &1["name"]) |> Enum.sort() == expected_names

      intel_tool = Enum.find(tools, &(&1["name"] == "horizon_intel_lookup"))
      input_props = get_in(intel_tool, ["inputSchema", "properties", "input", "properties"]) || %{}

      assert {input_props["asn"]["type"], input_props["prefix"]["type"], input_props["ip"]["type"]} ==
               {"integer", "string", "string"}

      for {uri, expected_snippet} <- [
            {"serviceradar://srql/grammar", "in:horizon_isp_accountability"},
            {"serviceradar://srql/cookbook", "horizon_intel_lookup"},
            {"serviceradar://srql/entities", "`horizon_isp_accountability`"}
          ] do
        read_resp = post_mcp!(mcp_url, perms, rpc("resources/read", %{"uri" => uri}))
        text = read_resp.body["result"]["contents"] |> List.wrap() |> Enum.map_join(& &1["text"])
        assert text =~ expected_snippet
      end
    end

    test "returns Horizon entity slices via get_srql_catalog and docs via lookup_srql_docs over JSON-RPC", %{
      mcp_url: mcp_url
    } do
      perms = ["settings.mcp.manage", "observability.events.view", "observability.traces.view"]

      for entity <- ~w(horizon_outages horizon_bgp horizon_zombies horizon_paths horizon_isp_accountability) do
        cat_resp = post_mcp!(mcp_url, perms, tool_call_flat("get_srql_catalog", %{"entity" => entity}))
        assert cat_resp.status == 200
        assert cat_resp.body["result"]["isError"] != true
        assert Map.keys(decode_tool_json!(cat_resp.body)["entities"]) == [entity]
      end

      docs_resp =
        post_mcp!(
          mcp_url,
          perms,
          tool_call_flat("lookup_srql_docs", %{"query" => "horizon_isp_accountability"})
        )

      assert docs_resp.status == 200
      decoded_docs = decode_tool_json!(docs_resp.body)
      assert decoded_docs["hit_count"] > 0
      assert "catalog:horizon_isp_accountability" in Enum.map(decoded_docs["matches"], & &1["source"])
    end

    test "execute_srql refuses Horizon queries with starrocks_required when StarRocks is disabled", %{
      mcp_url: mcp_url,
      prev_starrocks: prev_starrocks
    } do
      events_perms = ["settings.mcp.manage", "observability.events.view"]

      Application.put_env(
        :serviceradar_core,
        StarRocks,
        prev_starrocks
        |> Keyword.put(:enabled, false)
        |> Keyword.put(:mysql, fn sql -> flunk("disabled StarRocks must not run SQL: #{sql}") end)
      )

      starrocks_off =
        post_mcp!(
          mcp_url,
          events_perms,
          tool_call_flat("execute_srql", %{"query" => "in:horizon_outages status:active limit:5"})
        )

      assert starrocks_off.status == 200
      assert starrocks_off.body["result"]["isError"] == true
      assert tool_text(starrocks_off.body) =~ "starrocks_required"
    end

    test "execute_srql compiles StarRocks SQL for all 5 Horizon entities when authorized", %{
      mcp_url: mcp_url,
      prev_starrocks: prev_starrocks
    } do
      events_perms = ["settings.mcp.manage", "observability.events.view"]
      traces_perms = ["settings.mcp.manage", "observability.traces.view"]
      parent = self()

      Application.put_env(
        :serviceradar_core,
        StarRocks,
        prev_starrocks
        |> Keyword.put(:enabled, true)
        |> Keyword.put(:mysql, fn sql ->
          send(parent, {:horizon_srql_sql, sql})
          {:ok, %Postgrex.Result{command: :select, columns: ["sample"], rows: [["ok"]], num_rows: 1}}
        end)
      )

      allowed_cases = [
        {events_perms, "in:horizon_outages status:active limit:5", "FROM serviceradar.horizon_outages"},
        {events_perms, "in:horizon_bgp kind:%leak% limit:5", "FROM serviceradar.horizon_bgp_events"},
        {events_perms, "in:horizon_zombies is_beacon:false limit:5", "FROM serviceradar.horizon_bgp_zombies"},
        {traces_perms, "in:horizon_paths mtu_blackhole_detected:true limit:5", "FROM serviceradar.horizon_path_hops"},
        {
          events_perms,
          "in:horizon_isp_accountability !first_blame_tier:healthy limit:5",
          "FROM serviceradar.horizon_isp_accountability_mv"
        }
      ]

      for {perms, query, expected_from} <- allowed_cases do
        resp = post_mcp!(mcp_url, perms, tool_call_flat("execute_srql", %{"query" => query}))
        assert resp.status == 200
        assert resp.body["result"]["isError"] != true
        assert %{"results" => [%{"sample" => "ok"}]} = decode_tool_json!(resp.body)
        assert_receive {:horizon_srql_sql, sql}
        assert sql =~ expected_from
      end
    end

    test "execute_srql enforces Horizon per-entity RBAC and rejects aliases and unsupported clauses", %{
      mcp_url: mcp_url,
      prev_starrocks: prev_starrocks
    } do
      events_perms = ["settings.mcp.manage", "observability.events.view"]
      traces_perms = ["settings.mcp.manage", "observability.traces.view"]
      parent = self()

      Application.put_env(
        :serviceradar_core,
        StarRocks,
        prev_starrocks
        |> Keyword.put(:enabled, true)
        |> Keyword.put(:mysql, fn sql ->
          send(parent, {:horizon_srql_sql, sql})
          {:ok, %Postgrex.Result{command: :select, columns: ["sample"], rows: [["ok"]], num_rows: 1}}
        end)
      )

      for {perms, query} <- [
            {traces_perms, "in:horizon_outages limit:5"},
            {traces_perms, "IN:horizon_bgp limit:5"},
            {traces_perms, "in:horizon_paths limit:5 IN:horizon_zombies"},
            {traces_perms, "in:horizon_isp_accountability limit:5"},
            {events_perms, "in:horizon_paths limit:5"},
            {events_perms, "in:horizon_outages limit:5 IN:horizon_paths"},
            {events_perms, "in:horizon_isp_accountability_mv limit:5"},
            {events_perms, "in:horizon_outage limit:5"}
          ] do
        resp = post_mcp!(mcp_url, perms, tool_call_flat("execute_srql", %{"query" => query}))
        assert resp.body["result"]["isError"] == true
        assert tool_text(resp.body) =~ "forbidden"
        refute_received {:horizon_srql_sql, _}
      end

      for {perms, query} <- [
            {events_perms, "in:horizon_outages stats:count() as n"},
            {traces_perms, "in:horizon_paths bucket:5m"}
          ] do
        resp = post_mcp!(mcp_url, perms, tool_call_flat("execute_srql", %{"query" => query}))
        assert resp.body["result"]["isError"] == true
        refute_received {:horizon_srql_sql, _}
      end
    end

    test "horizon_intel_lookup enforces settings.mcp.manage and observability.events.view RBAC", %{
      mcp_url: mcp_url
    } do
      stub_intel_upstream(self())

      no_mcp =
        post_mcp!(
          mcp_url,
          ["observability.events.view"],
          tool_call_flat("horizon_intel_lookup", %{"asn" => 64_496})
        )

      assert no_mcp.status == 403
      assert no_mcp.body["error"] == "forbidden"
      refute_received {:intel_proxy_req, _}

      no_events =
        post_mcp!(
          mcp_url,
          ["settings.mcp.manage", "observability.traces.view"],
          tool_call_flat("horizon_intel_lookup", %{"asn" => 64_496})
        )

      assert no_events.status == 200
      assert no_events.body["result"]["isError"] == true
      assert tool_text(no_events.body) =~ "forbidden"
      refute_received {:intel_proxy_req, _}
    end

    test "horizon_intel_lookup forwards IPv4 and IPv6 queries via HorizonProxy for flat and nested arguments", %{
      mcp_url: mcp_url
    } do
      events_perms = ["settings.mcp.manage", "observability.events.view"]
      stub_intel_upstream(self())

      flat_ok =
        post_mcp!(
          mcp_url,
          events_perms,
          tool_call_flat("horizon_intel_lookup", %{
            "asn" => 64_496,
            "prefix" => "198.51.100.0/24",
            "ip" => "198.51.100.1"
          })
        )

      assert flat_ok.status == 200
      assert decode_tool_json!(flat_ok.body) == %{"asn" => 64_496, "as_org" => "Example Net", "rpki_status" => "valid"}
      refute Jason.encode!(flat_ok.body) =~ @secret_api_key

      assert_receive {:intel_proxy_req, req_opts}
      assert req_opts[:method] == :get

      assert req_opts[:url] ==
               "#{@upstream_base}/api/v1/intel/lookup?asn=64496&ip=198.51.100.1&prefix=198.51.100.0%2F24"

      assert {"authorization", "Bearer #{@secret_api_key}"} in req_opts[:headers]

      ipv6_nested =
        post_mcp!(
          mcp_url,
          events_perms,
          tool_call_nested("horizon_intel_lookup", %{"ip" => "2001:db8::1", "prefix" => "2001:db8::/32"})
        )

      assert ipv6_nested.status == 200
      assert ipv6_nested.body["result"]["isError"] != true
      assert_receive {:intel_proxy_req, ipv6_req}

      assert ipv6_req[:url] ==
               "#{@upstream_base}/api/v1/intel/lookup?ip=2001%3Adb8%3A%3A1&prefix=2001%3Adb8%3A%3A%2F32"
    end

    test "horizon_intel_lookup rejects invalid ASN, IP, CIDR, and query-injection inputs", %{mcp_url: mcp_url} do
      events_perms = ["settings.mcp.manage", "observability.events.view"]
      stub_intel_upstream(self())

      for {bad_args, expected_msg} <- [
            {%{}, "at least one of asn, prefix, or ip"},
            {%{"asn" => 0}, "positive 32-bit integer"},
            {%{"asn" => -5}, "positive 32-bit integer"},
            {%{"asn" => 4_294_967_296}, "positive 32-bit integer"},
            {%{"ip" => "not-an-ip"}, "valid IPv4 or IPv6"},
            {%{"ip" => "198.51.100.1&token=leaked"}, "valid IPv4 or IPv6"},
            {%{"prefix" => "198.51.100.0/33"}, "CIDR"},
            {%{"prefix" => "2001:db8::/129"}, "CIDR"},
            {%{"prefix" => "198.51.100.0/24&token=leaked"}, "CIDR"}
          ] do
        bad = post_mcp!(mcp_url, events_perms, tool_call_flat("horizon_intel_lookup", bad_args))
        assert bad.body["result"]["isError"] == true
        assert tool_text(bad.body) =~ expected_msg
        refute_received {:intel_proxy_req, _}
      end
    end

    test "horizon_intel_lookup maps HorizonProxy errors without leaking secrets", %{mcp_url: mcp_url} do
      events_perms = ["settings.mcp.manage", "observability.events.view"]

      error_cases = [
        {{:error, :not_configured}, nil, "horizon is not configured"},
        {{:ok, %{base_url: "https://169.254.169.254", api_key: @secret_api_key}}, nil, "invalid"},
        {{:ok, %{base_url: @upstream_base, api_key: @secret_api_key}},
         fn _ -> {:error, %Req.TransportError{reason: :timeout}} end, "timed out"},
        {{:ok, %{base_url: @upstream_base, api_key: @secret_api_key}},
         fn _ ->
           {:ok, %Req.Response{status: 404, headers: %{}, body: Jason.encode!(%{"error" => "intel_not_found"})}}
         end, "intel_not_found"},
        {{:ok, %{base_url: @upstream_base, api_key: @secret_api_key}},
         fn _ -> {:ok, %Req.Response{status: 200, headers: %{}, body: "not-json"}} end, "invalid JSON"}
      ]

      for {upstream_result, http_client, expected_msg} <- error_cases do
        Application.put_env(:serviceradar_web_ng, :horizon_proxy_upstream_resolver, fn -> upstream_result end)

        if is_function(http_client, 1) do
          Application.put_env(:serviceradar_web_ng, :horizon_proxy_http_client, http_client)
        end

        resp = post_mcp!(mcp_url, events_perms, tool_call_flat("horizon_intel_lookup", %{"asn" => 64_496}))
        assert resp.body["result"]["isError"] == true
        assert tool_text(resp.body) =~ expected_msg
        refute Jason.encode!(resp.body) =~ @secret_api_key
      end
    end
  end

  defp stub_intel_upstream(parent) do
    Application.put_env(:serviceradar_web_ng, :horizon_proxy_upstream_resolver, fn ->
      {:ok, %{base_url: @upstream_base, api_key: @secret_api_key}}
    end)

    Application.put_env(:serviceradar_web_ng, :horizon_proxy_http_client, fn req_opts ->
      send(parent, {:intel_proxy_req, req_opts})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"content-type" => ["application/json"]},
         body: Jason.encode!(%{"asn" => 64_496, "as_org" => "Example Net", "rpki_status" => "valid"})
       }}
    end)
  end

  defp post_mcp!(mcp_url, perms, payload) do
    Req.post!(mcp_url <> "/",
      json: payload,
      headers: [
        {"accept", "application/json"},
        {"x-test-permissions", Enum.join(perms, ",")}
      ],
      retry: false
    )
  end

  defp authorize_params(challenge, redirect_uri) do
    %{
      "response_type" => "code",
      "client_id" => @client_id,
      "redirect_uri" => redirect_uri,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "scope" => "mcp read",
      "state" => "state-proto-1"
    }
  end

  defp initialize_params do
    %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "mcp-horizon-protocol-test", "version" => "0.0.1"}
    }
  end

  defp tool_call_flat(name, args) do
    rpc("tools/call", %{"name" => name, "arguments" => args})
  end

  defp tool_call_nested(name, args) do
    rpc("tools/call", %{"name" => name, "arguments" => %{"input" => args}})
  end

  defp rpc(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  end

  defp tool_text(body) do
    body
    |> get_in(["result", "content"])
    |> List.wrap()
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  defp decode_tool_json!(body) do
    body
    |> tool_text()
    |> Jason.decode!()
  end

  defp clear_rate_limiter do
    table = RateLimiter.__table__()

    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end
  end

  defp restore_web_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_web_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defmodule McpTestPlug do
    @moduledoc false
    use Plug.Builder

    alias Ash.PlugHelpers
    alias Plug.Parsers
    alias ServiceRadarWebNG.Accounts.Scope
    alias ServiceRadarWebNGWeb.Plugs.McpAshContext
    alias ServiceRadarWebNGWeb.Plugs.McpRequirePermission

    plug(Parsers,
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: Jason
    )

    plug(:inject_scope)
    plug(McpRequirePermission)
    plug(McpAshContext)

    plug(AshAi.Mcp.Router,
      otp_app: :serviceradar_web_ng,
      tools: Mcp.v1_tools(),
      mcp_resources: Mcp.v1_resources(),
      protocol_version_statement: "2025-03-26",
      mcp_name: "serviceradar",
      tool_argument_transformer: &Mcp.wrap_tool_arguments/3,
      instructions: Mcp.instructions()
    )

    defp inject_scope(conn, _opts) do
      perms =
        conn
        |> get_req_header("x-test-permissions")
        |> List.first("")
        |> String.split(",", trim: true)
        |> MapSet.new()

      user = %{
        id: "00000000-0000-4000-8000-000000000042",
        email: "mcp-protocol@example.com",
        role: :viewer,
        role_profile_id: nil,
        permissions: perms
      }

      scope = Scope.for_user(user, permissions: perms)

      conn
      |> assign(:current_scope, scope)
      |> assign(:oauth_client_id, "serviceradar-mcp")
      |> PlugHelpers.set_actor(user)
    end
  end
end
