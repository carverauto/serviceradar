defmodule ServiceRadarWebNGWeb.BGPLive.TimestampRenderingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.BGPLive.Components
  alias ServiceRadarWebNGWeb.BGPLive.Index

  @moduletag :db_free

  @canonical "2026-01-15T18:30:00Z"
  @timezone "America/Chicago"

  test "chart component carries the saved zone separately from canonical payload instants" do
    html =
      render_component(&Components.traffic_timeseries_chart/1,
        timezone: @timezone,
        timeseries: timeseries()
      )

    chart = html |> LazyHTML.from_fragment() |> LazyHTML.query("#timeseries-chart")

    assert LazyHTML.attribute(chart, "phx-hook") == ["BGPTimeSeriesChart"]
    assert LazyHTML.attribute(chart, "data-timezone") == [@timezone]

    assert chart |> LazyHTML.attribute("data-data") |> List.first() |> Jason.decode!() ==
             timeseries().data
  end

  test "authenticated BGP page threads the persisted user zone into the chart" do
    html = render_component(&Index.render/1, page_assigns())
    chart = html |> LazyHTML.from_fragment() |> LazyHTML.query("#timeseries-chart")

    assert LazyHTML.attribute(chart, "data-timezone") == [@timezone]

    assert chart |> LazyHTML.attribute("data-data") |> List.first() |> Jason.decode!() ==
             timeseries().data
  end

  defp timeseries do
    %{
      series: ["64512"],
      data: [%{"time" => @canonical, "values" => %{"64512" => 10}}]
    }
  end

  defp page_assigns do
    %{
      flash: %{},
      current_scope: %{
        user: %{email: "operator@example.com", role: :operator, timezone: @timezone}
      },
      srql: %{enabled: false, page_path: "/observability/bgp"},
      bgp_live?: false,
      has_data: true,
      time_range: "last_1h",
      source_protocol: nil,
      selected_as: nil,
      selected_community: nil,
      data_sources: [],
      traffic_timeseries: timeseries(),
      traffic_data: [],
      max_bytes: 1,
      communities: [],
      path_diversity: %{unique_paths: 0, avg_path_length: 0.0, hop_distribution: %{}},
      topology: [],
      as_path_details: [],
      prefix_analysis: []
    }
  end
end
