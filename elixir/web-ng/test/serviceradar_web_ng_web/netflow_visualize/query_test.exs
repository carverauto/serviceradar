defmodule ServiceRadarWebNGWeb.NetflowVisualize.QueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowVisualize.Query

  @moduletag :db_free

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

  test "load_sankey documents lumped tail semantics for fragmented endpoints" do
    result =
      Query.load_sankey(
        __MODULE__.SRQLStub,
        "in:flows time:last_1h limit:10",
        %{test_pid: self(), response: :fragmented_endpoint_tail},
        prefix: 24,
        dims: ["src_cidr", "dst_port", "dst_cidr"],
        max_edges: 2
      )

    assert_receive {:srql_query, query}
    assert query =~ "limit:2"
    assert query =~ "other:true"

    assert [
             %{src: "192.0.2.0/24", mid: "https", dst: "203.0.113.0/24", bytes: 450},
             %{src: "198.51.100.0/24", mid: "dns", dst: "203.0.113.0/24", bytes: 250},
             %{src: "Other (src)", mid: "Other", dst: "Other (dst)", bytes: 900}
           ] = result.edges

    refute Enum.any?(result.edges, &(&1.src == "10.0.0.0/24"))
    assert {"Other (src)", 900} in result.sources
  end

  defmodule SRQLStub do
    @moduledoc false

    def query(query, %{scope: %{test_pid: pid} = scope}) do
      send(pid, {:srql_query, query})

      results =
        case Map.get(scope, :response) do
          :fragmented_endpoint_tail -> fragmented_endpoint_tail_results()
          _ -> default_results()
        end

      {:ok, %{"results" => results}}
    end

    defp default_results do
      [
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
    end

    defp fragmented_endpoint_tail_results do
      [
        %{
          "src_cidr" => "192.0.2.0/24",
          "dst_endpoint_port" => 443,
          "dst_cidr" => "203.0.113.0/24",
          "total_bytes" => 450
        },
        %{
          "src_cidr" => "198.51.100.0/24",
          "dst_endpoint_port" => 53,
          "dst_cidr" => "203.0.113.0/24",
          "total_bytes" => 250
        },
        %{
          "__other__" => true,
          "src_cidr" => nil,
          "dst_endpoint_port" => nil,
          "dst_cidr" => nil,
          "total_bytes" => 900
        }
      ]
    end
  end
end
