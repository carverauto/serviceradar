defmodule ServiceRadarWebNGWeb.NetflowVisualize.QueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowVisualize.Query

  test "load_sankey leaves limiting to the render bucketing layer" do
    result =
      Query.load_sankey(SRQLStub, "in:flows time:last_1h limit:10", %{test_pid: self()},
        prefix: 24,
        dims: ["src_cidr", "dst_port", "dst_cidr"],
        max_edges: 1
      )

    assert_receive {:srql_query, query}
    assert query =~ ~s|stats:"sum(bytes_total) as total_bytes by src_cidr:24, dst_endpoint_port, dst_cidr:24"|
    assert query =~ "sort:total_bytes:desc"
    refute query =~ "limit:"
    assert length(result.edges) == 3
  end

  defmodule SRQLStub do
    @moduledoc false

    def query(query, %{scope: %{test_pid: pid}}) do
      send(pid, {:srql_query, query})

      {:ok,
       %{
         "results" => [
           %{
             "src_cidr" => "10.0.0.0/24",
             "dst_endpoint_port" => 443,
             "dst_cidr" => "198.51.100.0/24",
             "total_bytes" => 300
           },
           %{
             "src_cidr" => "10.0.1.0/24",
             "dst_endpoint_port" => 53,
             "dst_cidr" => "203.0.113.0/24",
             "total_bytes" => 200
           },
           %{
             "src_cidr" => "10.0.2.0/24",
             "dst_endpoint_port" => 22,
             "dst_cidr" => "192.0.2.0/24",
             "total_bytes" => 100
           }
         ]
       }}
    end
  end
end
