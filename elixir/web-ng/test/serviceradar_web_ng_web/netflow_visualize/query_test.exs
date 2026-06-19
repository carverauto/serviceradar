defmodule ServiceRadarWebNGWeb.NetflowVisualize.QueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowVisualize.Query

  test "load_sankey asks SRQL for an Other rollup and renders the tail row" do
    result =
      Query.load_sankey(__MODULE__.SRQLStub, "in:flows time:last_1h limit:10", %{test_pid: self()},
        prefix: 24,
        dims: ["src_cidr", "dst_port", "dst_cidr"],
        max_edges: 1
      )

    assert_receive {:srql_query, query}
    assert query =~ ~s|stats:"sum(bytes_total) as total_bytes by src_cidr:24, dst_endpoint_port, dst_cidr:24"|
    assert query =~ "sort:total_bytes:desc"
    assert query =~ "limit:1"
    assert query =~ "other:true"

    assert [
             %{src: "10.0.0.0/24", mid: "https", dst: "198.51.100.0/24", bytes: 300},
             %{src: "Other (src)", mid: "Other", dst: "Other (dst)", bytes: 300}
           ] = result.edges
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
             "__other__" => true,
             "src_cidr" => nil,
             "dst_endpoint_port" => nil,
             "dst_cidr" => nil,
             "total_bytes" => 300
           }
         ]
       }}
    end
  end
end
