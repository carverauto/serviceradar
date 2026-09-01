defmodule ServiceRadarWebNGWeb.Components.AuthoredDashboardPanelComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelComponents

  @moduletag :db_free

  test "table localizes ISO string values from datetime-typed SRQL fields" do
    html =
      render_component(&PanelComponents.render_visual/1, %{
        panel: %{
          id: "panel-iso-time",
          visual_type: :table,
          title: "Recent events",
          data_binding: %{},
          display_config: %{},
          visual_config: %{}
        },
        rows: [%{"id" => "event-1", "observed_at" => "2026-08-30T18:00:00Z"}],
        fields: [%{name: "id", type: :string}, %{name: "observed_at", type: :datetime}],
        timezone: "America/Chicago"
      })

    document = LazyHTML.from_fragment(html)
    time = LazyHTML.query(document, "time")

    assert LazyHTML.attribute(time, "datetime") == ["2026-08-30T18:00:00Z"]
    assert LazyHTML.attribute(time, "data-user-time-zone") == ["America/Chicago"]
  end

  test "table timestamp hook ids do not collide after DOM-safe normalization" do
    html =
      render_component(&PanelComponents.render_visual/1, %{
        panel: %{
          id: "panel-collisions",
          visual_type: :table,
          title: "Recent events",
          data_binding: %{},
          display_config: %{},
          visual_config: %{}
        },
        rows: [
          %{"id" => "event a", "observed at" => "2026-08-30T18:00:00Z"},
          %{"id" => "event-a", "observed at" => "2026-08-30T19:00:00Z"}
        ],
        fields: [%{name: "observed at", type: :datetime}],
        timezone: "America/Chicago"
      })

    ids =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("time")
      |> LazyHTML.attribute("id")

    assert length(ids) == 2
    assert length(Enum.uniq(ids)) == 2
  end

  test "pivot localizes datetime row and column dimensions without changing grouping keys" do
    html =
      render_component(&PanelComponents.render_visual/1, %{
        panel: %{
          id: "panel-pivot-time",
          visual_type: :pivot,
          title: "Event windows",
          data_binding: %{
            "row_field" => "started_at",
            "column_field" => "ended_at",
            "value_field" => "count"
          },
          display_config: %{},
          visual_config: %{}
        },
        rows: [
          %{
            "started_at" => "2026-08-30T18:00:00Z",
            "ended_at" => "2026-08-30T19:00:00Z",
            "count" => 3
          }
        ],
        fields: [
          %{name: "started_at", type: :datetime},
          %{name: "ended_at", type: :datetime},
          %{name: "count", type: :number}
        ],
        timezone: "America/Chicago"
      })

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time[phx-hook='UserTime']")

    assert LazyHTML.attribute(times, "datetime") == [
             "2026-08-30T19:00:00Z",
             "2026-08-30T18:00:00Z"
           ]

    assert LazyHTML.attribute(times, "data-user-time-zone") == [
             "America/Chicago",
             "America/Chicago"
           ]

    value_cell = LazyHTML.query(document, "tbody tr > td:nth-child(2)")
    assert value_cell |> LazyHTML.text() |> String.trim() == "3.0"
  end

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
    assert html =~ "50.00 -&gt; 75.00 (+25.00)"
    refute html =~ "75 -&gt; 50"
  end

  test "stat aggregates all returned rows for bound value fields" do
    html =
      render_component(&PanelComponents.render_visual/1, %{
        panel: %{
          id: "panel-1",
          visual_type: :stat,
          title: "Total Services",
          data_binding: %{"value_field" => "value", "aggregate" => "sum"},
          display_config: %{"label" => "Total Services"},
          visual_config: %{}
        },
        rows: [%{"value" => 10}, %{"value" => 15}, %{"value" => 20}],
        fields: [%{name: "value", type: :number}],
        trend: nil
      })

    assert html =~ "45.00"
    refute html =~ "10.00"
  end

  test "stat trend orders by numeric epoch timestamp without using it as the value field" do
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
               %{"timestamp" => 1_782_211_800, "value" => 75},
               %{"timestamp" => 1_782_211_200, "value" => 50}
             ],
             fields: [%{name: "timestamp", type: :number}, %{name: "value", type: :number}]
           }}
      })

    assert html =~ "+50.0%"
    assert html =~ "50.00 -&gt; 75.00 (+25.00)"
    refute html =~ "1782211200"
  end
end
