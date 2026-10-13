defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.LeaseHorizonsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.LeaseHorizons

  @moduletag :db_free

  test "an acknowledged empty lease shows zero slots and a dash only when the count is missing" do
    html =
      render_component(&LeaseHorizons.panel/1,
        group_id: "group-1",
        timezone: "Etc/UTC",
        now: ~U[2026-10-12 12:00:00Z],
        agents: %{},
        horizons: [
          horizon("empty", 0),
          horizon("missing", nil)
        ]
      )

    document = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.query("#sweep-lease-slots-empty")
           |> LazyHTML.text()
           |> String.trim() == "0"

    assert document
           |> LazyHTML.query("#sweep-lease-slots-missing")
           |> LazyHTML.text()
           |> String.trim() == "—"
  end

  test "a horizon 48 hours and 30 minutes out stays labeled 2d left" do
    now = ~U[2026-10-12 12:00:00Z]
    through = DateTime.add(now, 48 * 3600 + 30 * 60, :second)

    assert LeaseHorizons.format_remaining(through, now) == "2d left"

    assert LeaseHorizons.format_remaining(through, DateTime.add(now, 29 * 60, :second)) ==
             "2d left"
  end

  defp horizon(id, slot_count) do
    %{
      sweep_group_id: "group-1",
      producer_assignment_id: id,
      agent_id: "agent-#{id}",
      status: :acknowledged,
      acknowledged_through: nil,
      acknowledged_slot_count: slot_count,
      acknowledged_at: nil,
      error: nil
    }
  end
end
