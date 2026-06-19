defmodule ServiceRadarWebNGWeb.Components.AuthoredDashboardPanelComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelComponents

  test "stat trend compares oldest and newest rows by time" do
    html =
      render_component(&PanelComponents.render_visual/1, %{
        panel: %{
          id: "panel-1",
          visual_type: :stat,
          title: "Current Services",
          data_binding: %{"value_field" => "value"},
          display_config: %{"label" => "Current Services"},
          visual_config: %{"trend_lookback_days" => 1}
        },
        rows: [%{"value" => 75}],
        fields: [%{name: "value", type: :number}],
        trend:
          {:ok,
           %{
             rows: [
               %{"timestamp" => "2026-06-19T00:10:00Z", "value" => 75},
               %{"timestamp" => "2026-06-19T00:00:00Z", "value" => 50}
             ],
             fields: [%{name: "timestamp", type: :datetime}, %{name: "value", type: :number}]
           }}
      })

    assert html =~ "+50.0%"
    assert html =~ "50 -&gt; 75 (+25)"
    refute html =~ "75 -&gt; 50"
  end
end
