defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelParamsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelParams

  test "stores capacity forecast mode in display config" do
    attrs =
      PanelParams.attrs(%{
        "title" => "Interface runway",
        "srql_query" => "in:capacity_forecasts status:projected limit:25",
        "visual_type" => "line",
        "capacity_forecast_mode" => "capacity_forecast",
        "time_field" => "forecasted_at",
        "value_field" => "projected_value"
      })

    assert attrs.display_config["capacity_forecast"] == true
  end

  test "round-trips capacity forecast mode from a panel" do
    panel = %{
      dataset_key: "capacity",
      title: "Interface runway",
      srql_query: "in:capacity_forecasts status:projected limit:25",
      visual_type: :line,
      data_binding: %{"time_field" => "forecasted_at", "value_field" => "projected_value"},
      display_config: %{"capacity_forecast" => true},
      visual_config: %{},
      layout: %{}
    }

    assert PanelParams.from_panel(panel)["capacity_forecast_mode"] == "capacity_forecast"
  end
end
