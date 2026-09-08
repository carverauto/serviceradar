defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponents

  @moduletag :db_free

  test "identifies the host count as belonging to the latest execution" do
    older = execution("ot-managed", 5_993, 4_384, ~U[2026-08-30 23:33:00Z])
    latest = execution("rids", 365, 141, ~U[2026-08-30 23:36:00Z])

    document =
      (&ActiveScansComponents.scan_statistics/1)
      |> render_component(
        running: [],
        recent: [older, latest],
        groups: [
          %{id: "ot-managed", name: "OT managed"},
          %{id: "rids", name: "RIDS"}
        ],
        timezone: "America/Chicago"
      )
      |> LazyHTML.from_fragment()

    card = LazyHTML.query(document, "#active-scans-latest-execution")
    assert Enum.count(card) == 1

    text = LazyHTML.text(card)

    assert text =~ "Latest Execution"
    assert text =~ "365 hosts"
    assert text =~ "RIDS"
    assert text =~ "141 available"
    refute text =~ "5,993"
    refute text =~ "Hosts Scanned"

    time = LazyHTML.query(card, "#settings-active-scan-latest-completed-at")
    assert LazyHTML.attribute(time, "datetime") == ["2026-08-30T23:36:00Z"]
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
      started_at: DateTime.add(completed_at, -5, :second)
    }
  end
end
