defmodule ServiceRadarWebNGWeb.Settings.ClusterLiveDeadLettersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Settings.ClusterLive.DeadLetters

  @moduletag :db_free

  @plugin_group %{
    contract: "serviceradar.plugin_results.batch/1",
    reason: "missing_synthetic_capability",
    count: 261,
    first_sequence: 2,
    last_sequence: 262,
    first_stored_at: "2026-11-06T20:48:51.731669434Z",
    last_stored_at: "2026-11-07T00:33:53.100000Z",
    agents: ["agent-synthetic-01", "agent-synthetic-02"],
    agent_count: 2,
    reason_detail: "synthetic capability refusal"
  }

  test "each held group is a row with its count, agents and actions, and purge all covers them" do
    html =
      render_component(&DeadLetters.groups_table/1,
        inventory: %{groups: [@plugin_group], scanned: 261, complete: true}
      )

    assert html |> cells("#dead-letters-group-0 td") |> Enum.take(4) == [
             "serviceradar.plugin_results.batch/1",
             "missing_synthetic_capability",
             "261",
             "agent-synthetic-01 +1"
           ]

    assert html =~ "2026-11-06 20:48 UTC"
    assert html =~ ~s(phx-value-action="replay")
    assert html =~ ~s(phx-value-action="purge")
    assert html =~ ~s(id="dead-letters-purge-all")
    refute html =~ "dead-letters-partial"
  end

  test "a partial read says so, and an empty stream offers no actions" do
    partial =
      render_component(&DeadLetters.groups_table/1,
        inventory: %{groups: [@plugin_group], scanned: 5_000, complete: false}
      )

    assert partial =~ ~s(id="dead-letters-partial")
    assert partial =~ "Showing the first 5000 dead letters"

    empty =
      render_component(&DeadLetters.groups_table/1,
        inventory: %{groups: [], scanned: 0, complete: true}
      )

    assert empty =~ ~s(id="dead-letters-empty")
    refute empty =~ "dead-letters-purge-all"
  end

  defp cells(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
