defmodule ServiceRadarWebNG.McpRunnerUnitTest do
  use ExUnit.Case, async: false

  alias Ash.Error.Action.InvalidArgument
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStore
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Mcp.Runner
  alias ServiceRadarWebNG.TestSupport.McpSRQLTranslationProbe

  @moduletag :db_free

  defmodule FakeGraphStore do
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
    def blast_radius(seed, opts) do
      send(self(), {:graph_blast_radius, seed, opts})
      {:ok, %{"seed_id" => seed, "internal_devices" => [%{"id" => "sr:edge-01"}], "edges" => []}}
    end

    @impl true
    def shared_fate_spofs(opts) do
      send(self(), {:graph_shared_fate_spofs, opts})
      {:ok, [%{"id" => "asn:64512", "target_count" => 3}]}
    end

    @impl true
    def customer_cone_impact(asn, opts) do
      send(self(), {:graph_customer_cone, asn, opts})
      {:ok, %{"asn_id" => to_string(asn), "prefixes" => [%{"id" => "198.51.100.0/24"}], "edges" => []}}
    end

    @impl true
    def multi_hop_trace(query, opts) do
      send(self(), {:graph_multi_hop_trace, query, opts})
      {:ok, %{"found" => true, "hops" => 2, "nodes" => [], "edges" => []}}
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    prev_client = Application.get_env(:serviceradar_web_ng, :horizon_proxy_http_client)
    prev_resolver = Application.get_env(:serviceradar_web_ng, :horizon_proxy_upstream_resolver)
    prev_graph = Application.get_env(:serviceradar_core, TopologyGraph)
    Application.put_env(:serviceradar_web_ng, :srql_module, McpSRQLTranslationProbe)

    on_exit(fn ->
      restore_env(:srql_module, previous)
      restore_env(:horizon_proxy_http_client, prev_client)
      restore_env(:horizon_proxy_upstream_resolver, prev_resolver)

      if is_nil(prev_graph) do
        Application.delete_env(:serviceradar_core, TopologyGraph)
      else
        Application.put_env(:serviceradar_core, TopologyGraph, prev_graph)
      end
    end)
  end

  test "execute_srql uses an in-query limit unless the tool limit is explicitly set" do
    context = %{context: %{scope: %{permissions: MapSet.new(["devices.view"])}}}

    cases = [
      {%{query: "in:devices limit:3"}, 3},
      {%{query: "in:devices limit:3", limit: nil}, 3},
      {%{query: "in:devices limit:3", limit: 2}, 2},
      {%{query: "in:devices limit:3", limit: 10_000}, 500}
    ]

    for {arguments, expected_limit} <- cases do
      input = %{arguments: arguments}

      assert {:ok, %{"pagination" => %{"limit" => ^expected_limit}}} =
               Runner.execute_srql(input, context)
    end
  end

  test "execute_srql translates the catalog-advertised mtr_traces entity" do
    context = %{
      context: %{scope: %{permissions: MapSet.new(["observability.traces.view"])}}
    }

    input = %{
      arguments: %{
        query: "in:mtr_traces time:last_1h sort:time:desc limit:1"
      }
    }

    assert {:ok, %{"pagination" => %{"limit" => 1}}} =
             Runner.execute_srql(input, context)
  end

  test "execute_srql refuses an unknown entity and a quoted escape of a gated one" do
    context = %{context: %{scope: %{permissions: MapSet.new(["observability.logs.view"])}}}

    for query <- ["in:not_a_real_entity_zzz", ~S(in:"dev\ices" limit:1)] do
      assert {:error, %InvalidArgument{message: "forbidden"}} =
               Runner.execute_srql(%{arguments: %{query: query}}, context)
    end
  end

  test "execute_srql enforces RBAC on Horizon entities" do
    events_ctx = %{context: %{scope: %Scope{permissions: MapSet.new(["observability.events.view"])}}}
    traces_ctx = %{context: %{scope: %Scope{permissions: MapSet.new(["observability.traces.view"])}}}

    for query <- [
          "in:horizon_outages status:active limit:5",
          "in:horizon_bgp kind:hijack limit:5",
          "in:horizon_zombies status:active limit:5",
          "in:horizon_isp_accountability limit:5"
        ] do
      assert {:error, %InvalidArgument{message: "forbidden"}} =
               Runner.execute_srql(%{arguments: %{query: query}}, traces_ctx)
    end

    assert {:error, %InvalidArgument{message: "forbidden"}} =
             Runner.execute_srql(%{arguments: %{query: "in:horizon_paths target_id:t1 limit:5"}}, events_ctx)
  end

  test "horizon_intel_lookup enforces observability.events.view RBAC" do
    denied_ctx = %{context: %{scope: %Scope{permissions: MapSet.new(["observability.traces.view"])}}}

    assert {:error, %InvalidArgument{message: "forbidden"}} =
             Runner.horizon_intel_lookup(%{arguments: %{asn: 13_335}}, denied_ctx)
  end

  test "horizon_intel_lookup validates inputs and forwards through HorizonProxy" do
    events_ctx = %{context: %{scope: %Scope{permissions: MapSet.new(["observability.events.view"])}}}

    assert {:error, %InvalidArgument{message: msg}} =
             Runner.horizon_intel_lookup(%{arguments: %{}}, events_ctx)

    assert msg =~ "at least one of asn, prefix, or ip"

    assert {:error, %InvalidArgument{message: msg}} =
             Runner.horizon_intel_lookup(%{arguments: %{prefix: "not-a-cidr"}}, events_ctx)

    assert msg =~ "CIDR"

    Application.put_env(:serviceradar_web_ng, :horizon_proxy_upstream_resolver, fn ->
      {:ok, %{base_url: "https://api.horizon.serviceradar.cloud", api_key: "hrz_test_key"}}
    end)

    Application.put_env(:serviceradar_web_ng, :horizon_proxy_http_client, fn req_opts ->
      send(self(), {:horizon_intel_req, req_opts})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{"content-type" => ["application/json"]},
         body: Jason.encode!(%{"asn" => 13_335, "as_org" => "Cloudflare, Inc.", "rpki_status" => "valid"})
       }}
    end)

    assert {:ok, %{"asn" => 13_335, "as_org" => "Cloudflare, Inc.", "rpki_status" => "valid"}} =
             Runner.horizon_intel_lookup(
               %{arguments: %{asn: 13_335, prefix: "1.1.1.0/24", ip: "1.1.1.1"}},
               events_ctx
             )

    assert_receive {:horizon_intel_req, req_opts}
    assert req_opts[:method] == :get

    assert req_opts[:url] ==
             "https://api.horizon.serviceradar.cloud/api/v1/intel/lookup?asn=13335&ip=1.1.1.1&prefix=1.1.1.0%2F24"
  end

  test "topology_blast_radius enforces RBAC, validates scalars, and clamps bounds" do
    denied_ctx = %{context: %{scope: %Scope{permissions: MapSet.new(["observability.traces.view"])}}}
    events_ctx = %{context: %{scope: %Scope{permissions: MapSet.new(["observability.events.view"])}}}
    Application.put_env(:serviceradar_core, TopologyGraph, graph_store: FakeGraphStore)

    assert {:error, %InvalidArgument{message: "forbidden"}} =
             Runner.topology_blast_radius(%{arguments: %{mode: "blast_radius", seed: "asn:64512"}}, denied_ctx)

    assert {:error, %InvalidArgument{message: msg}} =
             Runner.topology_blast_radius(%{arguments: %{mode: "invalid_mode"}}, events_ctx)

    assert msg =~ "mode must be one of"

    assert {:error, %InvalidArgument{message: seed_msg}} =
             Runner.topology_blast_radius(
               %{arguments: %{mode: "blast_radius", seed: "bad\"seed\\injection"}},
               events_ctx
             )

    assert seed_msg =~ "invalid seed"

    assert {:ok, %{"mode" => "blast_radius", "seed_id" => "asn:64512"}} =
             Runner.topology_blast_radius(
               %{arguments: %{mode: "blast_radius", seed: "asn:64512", max_hops: 99, limit: 999}},
               events_ctx
             )

    assert_receive {:graph_blast_radius, "asn:64512", opts}
    assert opts[:max_hops] == 8
    assert opts[:limit] == 200

    assert {:ok, %{"mode" => "shared_fate_spofs", "count" => 1}} =
             Runner.topology_blast_radius(%{arguments: %{mode: "shared_fate_spofs"}}, events_ctx)

    assert_receive {:graph_shared_fate_spofs, _}

    for valid_v6 <- ["::1", "::/0", "::ffff:192.0.2.1"] do
      assert {:ok, %{"mode" => "blast_radius", "seed_id" => ^valid_v6}} =
               Runner.topology_blast_radius(
                 %{arguments: %{mode: "blast_radius", seed: valid_v6}},
                 events_ctx
               )

      assert_receive {:graph_blast_radius, ^valid_v6, _}
    end

    for bad_seed <- ["::1\" ) {", "::1/999", "::evil", "sr:bad\nnode", "sr:bad node", "sr:bad{node}"] do
      assert {:error, %InvalidArgument{message: bad_msg}} =
               Runner.topology_blast_radius(
                 %{arguments: %{mode: "blast_radius", seed: bad_seed}},
                 events_ctx
               )

      assert bad_msg =~ "invalid seed"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
