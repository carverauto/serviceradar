defmodule ServiceRadarWebNGWeb.McpTopologyGraphProtocolTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStore
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Mcp

  @moduletag :db_free

  defmodule StubGraphStore do
    @moduledoc false
    @behaviour GraphStore

    @impl true
    def writable?, do: true
    @impl true
    def upsert_interfaces(_), do: :ok
    @impl true
    def upsert_links(_), do: :ok
    @impl true
    def upsert_managed_by(_, _), do: :ok
    @impl true
    def upsert_mtr_path(_), do: :ok
    @impl true
    def upsert_risk_summary(_, _), do: :ok
    @impl true
    def project_config_facts(_), do: :ok
    @impl true
    def prune_stale(_, _), do: :ok
    @impl true
    def upsert_external_topology(_, _), do: {:ok, %{}}
    @impl true
    def upsert_external_status(_, _), do: :ok
    @impl true
    def prune_stale_external(_, _), do: {:ok, 0}

    @impl true
    def blast_radius(seed, _opts) do
      {:ok,
       %{
         "seed_id" => seed,
         "max_hops" => 4,
         "truncated" => false,
         "internal_devices" => [%{"id" => "sr:edge-01", "kind" => "Device"}],
         "prefixes" => [%{"id" => "198.51.100.0/24", "kind" => "Prefix"}],
         "external_nodes" => [%{"id" => "saas:api.example", "kind" => "SaasTarget"}],
         "edges" => []
       }}
    end

    @impl true
    def shared_fate_spofs(_opts) do
      {:ok, [%{"id" => "ixp:64512", "kind" => "IXP", "target_count" => 3, "device_count" => 2}]}
    end

    @impl true
    def customer_cone_impact(asn, _opts) do
      {:ok,
       %{
         "asn_id" => to_string(asn),
         "prefixes" => [%{"id" => "203.0.113.0/24", "rpki_state" => "valid"}],
         "impacted_devices" => [%{"id" => "sr:edge-01"}],
         "edges" => []
       }}
    end

    @impl true
    def multi_hop_trace(query, _opts) do
      {:ok,
       %{
         "src_id" => query[:from],
         "dst_id" => query[:to],
         "found" => true,
         "hops" => 2,
         "nodes" => [%{"id" => query[:from]}, %{"id" => "transit:192.0.2.1"}, %{"id" => query[:to]}],
         "edges" => []
       }}
    end
  end

  defmodule McpGraphTestPlug do
    @moduledoc false
    use Plug.Builder

    alias Ash.PlugHelpers
    alias Plug.Parsers
    alias ServiceRadarWebNG.Accounts.Scope
    alias ServiceRadarWebNGWeb.Plugs.McpAshContext
    alias ServiceRadarWebNGWeb.Plugs.McpRequirePermission

    plug(Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
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
        id: "00000000-0000-4000-8000-000000000099",
        email: "mcp-graph@example.com",
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

  setup_all do
    {:ok, _} = Application.ensure_all_started(:plug)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)

    if is_nil(Process.whereis(RateLimiter)) do
      start_supervised!(RateLimiter)
    end

    server =
      start_supervised!(
        {Bandit, plug: McpGraphTestPlug, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: :live_mcp_graph_bandit
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{mcp_url: "http://127.0.0.1:#{port}"}
  end

  setup do
    prev_mcp = Application.get_env(:serviceradar_web_ng, :mcp_enabled)
    prev_graph = Application.get_env(:serviceradar_core, TopologyGraph)

    Application.put_env(:serviceradar_web_ng, :mcp_enabled, true)
    Application.put_env(:serviceradar_core, TopologyGraph, graph_store: StubGraphStore)

    on_exit(fn ->
      if is_nil(prev_mcp) do
        Application.delete_env(:serviceradar_web_ng, :mcp_enabled)
      else
        Application.put_env(:serviceradar_web_ng, :mcp_enabled, prev_mcp)
      end

      if is_nil(prev_graph) do
        Application.delete_env(:serviceradar_core, TopologyGraph)
      else
        Application.put_env(:serviceradar_core, TopologyGraph, prev_graph)
      end
    end)

    :ok
  end

  test "exposes topology_blast_radius schema and executes all 4 reasoning modes over JSON-RPC", %{
    mcp_url: mcp_url
  } do
    perms = ["settings.mcp.manage", "observability.events.view"]

    tools_resp = post_mcp!(mcp_url, perms, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    tools = tools_resp.body["result"]["tools"]
    graph_tool = Enum.find(tools, &(&1["name"] == "topology_blast_radius"))
    assert graph_tool

    props = get_in(graph_tool, ["inputSchema", "properties", "input", "properties"]) || %{}
    assert props["mode"]["type"] == "string"
    assert props["seed"]["type"] == "string"
    assert props["max_hops"]["type"] == "integer"

    for {args, expected_mode} <- [
          {%{"mode" => "blast_radius", "seed" => "asn:64512", "max_hops" => 4}, "blast_radius"},
          {%{"mode" => "shared_fate_spofs", "min_targets" => 2, "limit" => 10}, "shared_fate_spofs"},
          {%{"mode" => "customer_cone", "seed" => "64512"}, "customer_cone"},
          {%{"mode" => "multi_hop_trace", "seed" => "sr:edge-01", "target" => "saas:api.example"}, "multi_hop_trace"}
        ] do
      resp =
        post_mcp!(mcp_url, perms, %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "topology_blast_radius", "arguments" => args}
        })

      assert resp.status == 200
      assert resp.body["result"]["isError"] != true
      decoded = resp.body |> get_in(["result", "content"]) |> hd() |> Map.fetch!("text") |> Jason.decode!()
      assert decoded["mode"] == expected_mode
    end
  end

  test "denies topology_blast_radius without observability.events.view over JSON-RPC", %{
    mcp_url: mcp_url
  } do
    perms = ["settings.mcp.manage", "observability.traces.view"]

    resp =
      post_mcp!(mcp_url, perms, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "topology_blast_radius",
          "arguments" => %{"mode" => "blast_radius", "seed" => "asn:64512"}
        }
      })

    assert resp.status == 200
    assert resp.body["result"]["isError"] == true
    text = resp.body |> get_in(["result", "content"]) |> hd() |> Map.fetch!("text")
    assert text =~ "forbidden"
  end

  defp post_mcp!(url, perms, payload) do
    Req.post!(url,
      json: payload,
      headers: [
        {"accept", "application/json"},
        {"x-test-permissions", Enum.join(perms, ",")}
      ],
      retry: false
    )
  end
end
