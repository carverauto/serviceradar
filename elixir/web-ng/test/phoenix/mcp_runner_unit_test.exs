defmodule ServiceRadarWebNG.McpRunnerUnitTest do
  use ExUnit.Case, async: false

  alias Ash.Error.Action.InvalidArgument
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Mcp.Runner
  alias ServiceRadarWebNG.TestSupport.McpSRQLTranslationProbe

  @moduletag :db_free

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    prev_client = Application.get_env(:serviceradar_web_ng, :horizon_proxy_http_client)
    prev_resolver = Application.get_env(:serviceradar_web_ng, :horizon_proxy_upstream_resolver)
    Application.put_env(:serviceradar_web_ng, :srql_module, McpSRQLTranslationProbe)

    on_exit(fn ->
      restore_env(:srql_module, previous)
      restore_env(:horizon_proxy_http_client, prev_client)
      restore_env(:horizon_proxy_upstream_resolver, prev_resolver)
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
