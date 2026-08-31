defmodule ServiceRadarWebNGWeb.Observability.SignalDisplayComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Observability.SignalDisplayComponents

  @moduletag :db_free

  test "renders only explicitly typed contract timestamps semantically with unique caller-qualified ids" do
    repeated_row = %{
      values: [%{label: "Updated", path: "updated_at", value: "2026-08-30T18:00:00Z", format: "timestamp"}]
    }

    html =
      render_component(&SignalDisplayComponents.signal_display_panel/1,
        id: "signal-review",
        timezone: "America/Chicago",
        widgets: [
          %{
            type: :badges,
            fields: [%{label: "Logged", value: "2026-08-30T18:00:00Z", tone: nil, format: "timestamp"}]
          },
          %{
            type: :facts,
            fields: [%{label: "Event time", value: "2026-08-30T18:00:00Z", format: "timestamp"}]
          },
          %{
            type: :timeline,
            fields: [%{label: "Observed", value: "1788112800000000000", format: "unix_nano"}]
          },
          %{
            type: :json_section,
            title: "Raw",
            sections: [
              %{
                value: %{
                  "observed_at" => "2026-08-30T18:00:00Z",
                  "updateTimestamp" => "2026-08-30T18:00:00Z",
                  "note" => "2026-08-30T18:00:00Z"
                }
              }
            ]
          },
          %{
            type: :table,
            title: "History",
            columns: [%{label: "Updated", path: "updated_at", format: "timestamp"}],
            rows: [repeated_row, repeated_row]
          }
        ]
      )

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time")
    ids = LazyHTML.attribute(times, "id")

    assert length(ids) == 7
    assert ids == Enum.uniq(ids)
    assert Enum.all?(ids, &String.starts_with?(&1, "signal-review-widget-"))
    assert LazyHTML.attribute(times, "data-user-time-zone") == List.duplicate("America/Chicago", 7)
    assert Enum.all?(LazyHTML.attribute(times, "datetime"), &String.starts_with?(&1, "2026-08-30T18:00:00"))
    assert html =~ "Note"
    assert html =~ "2026-08-30T18:00:00Z"
  end
end
