defmodule ServiceRadarWebNGWeb.Components.AuthoredDashboardChartTimezoneTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelComponents

  @moduletag :unit
  @moduletag :db_free

  test "threads the saved timezone and canonicalizes naive UTC chart timestamps" do
    panel = %{
      id: "panel-1",
      title: "Capacity",
      srql_query: "in:capacity_forecasts",
      visual_type: :line,
      data_binding: %{"time_field" => "forecasted_at", "value_field" => "current_value"},
      display_config: %{},
      visual_config: %{}
    }

    html =
      render_component(&PanelComponents.render_visual/1,
        panel: panel,
        rows: [
          %{
            "forecasted_at" => ~N[2026-08-30 18:00:00],
            "current_value" => 42
          }
        ],
        fields: [
          %{name: "forecasted_at", type: :datetime},
          %{name: "current_value", type: :number}
        ],
        timezone: "America/Chicago"
      )

    [encoded_props] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[phx-hook=DashboardPanelChart]")
      |> LazyHTML.attribute("data-props")

    assert %{
             "timezone" => "America/Chicago",
             "rows" => [%{"forecasted_at" => "2026-08-30T18:00:00Z"}]
           } = Jason.decode!(encoded_props)
  end
end
