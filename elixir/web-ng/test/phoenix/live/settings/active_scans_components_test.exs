defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponents

  @moduletag :db_free

  test "identifies the host count as belonging to the latest execution" do
    older = execution("lab-wide", 2_000, 1_500, ~U[2026-01-15 10:00:00Z])
    latest = execution("branch", 300, 120, ~U[2026-01-15 10:05:00Z])

    document =
      (&ActiveScansComponents.scan_statistics/1)
      |> render_component(
        running: [],
        recent: [older, latest],
        groups: [
          %{id: "lab-wide", name: "Lab wide"},
          %{id: "branch", name: "Branch office"}
        ],
        timezone: "America/Chicago"
      )
      |> LazyHTML.from_fragment()

    card = LazyHTML.query(document, "#active-scans-latest-execution")
    assert Enum.count(card) == 1

    text = LazyHTML.text(card)

    assert text =~ "Latest Execution"
    assert text =~ "300 hosts"
    assert text =~ "Branch office"
    assert text =~ "120 available"
    refute text =~ "2,000"
    refute text =~ "Hosts Scanned"

    time = LazyHTML.query(card, "#settings-active-scan-latest-completed-at")
    assert LazyHTML.attribute(time, "datetime") == ["2026-01-15T10:05:00Z"]
    assert LazyHTML.attribute(time, "data-user-time-zone") == ["America/Chicago"]
  end

  defp execution(group_id, hosts_total, hosts_available, completed_at) do
    %{
      status: :completed,
      sweep_group_id: group_id,
      hosts_total: hosts_total,
      hosts_available: hosts_available,
      scanner_metrics: %{},
      completed_at: completed_at,
      updated_at: completed_at,
      started_at: DateTime.shift(completed_at, second: -5)
    }
  end
end
