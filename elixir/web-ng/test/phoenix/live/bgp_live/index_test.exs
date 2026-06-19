defmodule ServiceRadarWebNGWeb.BGPLive.IndexTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.BGPLive.Index

  describe "bgp_statistics_assigns/1" do
    test "keeps successful data visible while reporting partial query failures" do
      assigns =
        Index.bgp_statistics_assigns(
          traffic_data: {:ok, [%{as_number: 64_512, bytes: 42_000, flow_count: 7}]},
          communities: {:error, %{postgres: %{message: "relation missing"}}},
          topology: {:ok, []}
        )

      assert assigns.has_data
      assert assigns.max_bytes == 42_000
      assert assigns.communities == []
      assert assigns.bgp_load_error == "top communities failed: relation missing"
    end

    test "distinguishes total query failure from no BGP rows" do
      assigns =
        Index.bgp_statistics_assigns(
          traffic_data: {:error, :db_unavailable},
          communities: {:error, :db_unavailable},
          topology: {:error, :db_unavailable}
        )

      refute assigns.has_data
      assert assigns.traffic_data == []
      assert assigns.traffic_timeseries == %{series: [], data: []}
      assert assigns.bgp_load_error =~ "traffic by AS failed: :db_unavailable"

      empty_state = Index.bgp_empty_state(assigns.bgp_load_error)

      assert empty_state.title == "BGP Query Failed"
      assert empty_state.body =~ "could not be loaded"
      assert empty_state.detail == assigns.bgp_load_error
    end

    test "keeps true no-data state separate from query errors" do
      assigns =
        Index.bgp_statistics_assigns(
          traffic_data: {:ok, []},
          communities: {:ok, []},
          topology: {:ok, []}
        )

      refute assigns.has_data
      assert is_nil(assigns.bgp_load_error)

      empty_state = Index.bgp_empty_state(assigns.bgp_load_error)

      assert empty_state.title == "No BGP Routing Data"
      assert empty_state.body =~ "No BGP observations"
    end
  end
end
