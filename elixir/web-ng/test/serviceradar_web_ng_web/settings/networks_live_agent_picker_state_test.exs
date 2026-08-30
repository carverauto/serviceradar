defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.AgentPickerStateTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Live.Settings.NetworksLive.AgentPicker

  @moduletag :db_free

  test "opens from committed IDs and normalizes a changed search before resetting cursors" do
    state = ["agent-b", "agent-a"] |> AgentPicker.new() |> AgentPicker.open()

    assert state.draft == MapSet.new(["agent-a", "agent-b"])
    assert state.committed == MapSet.new(["agent-a", "agent-b"])
    assert state.mode == :browse

    searched = AgentPicker.search(state, "  Mixed Case  ")
    assert searched.query == "mixed case"
    assert searched.cursor_history == []
    assert searched.cursor == nil
    assert searched.error == nil
  end

  test "keeps draft selections across browse pages and binds cursors to the normalized query" do
    state =
      []
      |> AgentPicker.new()
      |> AgentPicker.open()
      |> AgentPicker.loaded(%{results: [%{uid: "agent-a"}], after: "cursor-1", before: nil})
      |> AgentPicker.toggle("agent-a")
      |> AgentPicker.next_page()

    assert state.cursor == "cursor-1"
    assert state.cursor_history == [nil]
    assert %{query: "", sort: "agent-picker-name-uid-v1"} = state.cursor_binding
    assert %{search: "", selector: {:after, "cursor-1"}} = AgentPicker.browse_request(state)

    state =
      state
      |> AgentPicker.loaded(%{results: [%{uid: "agent-b"}], after: nil, before: "cursor-1"})
      |> AgentPicker.toggle("agent-b")

    assert AgentPicker.next_page(state) == state

    state = AgentPicker.previous_page(state)

    assert state.cursor == nil
    assert state.cursor_history == []
    assert state.draft == MapSet.new(["agent-a", "agent-b"])

    reset = AgentPicker.search(state, " another query ")
    assert reset.query == "another query"
    assert reset.cursor == nil
    assert reset.cursor_history == []
    assert reset.cursor_binding == nil
    assert %{search: "another query", selector: :first} = AgentPicker.browse_request(reset)
  end

  test "switches between Browse and selected pages without resolving more than fifty sorted UIDs" do
    ids = for index <- 1..51, do: "agent-#{String.pad_leading(Integer.to_string(52 - index), 3, "0")}"

    state = ids |> AgentPicker.new() |> AgentPicker.open() |> AgentPicker.show_selected()

    assert :selected == state.mode
    assert ids |> Enum.sort() |> Enum.take(50) == AgentPicker.selected_page(state)

    state = AgentPicker.selected_page(state, 50)
    assert ["agent-051"] == AgentPicker.selected_page(state)
    assert :browse == AgentPicker.show_browse(state).mode
  end

  test "removes, clears, applies, and cancels without conflating draft and committed IDs" do
    state = ["agent-a"] |> AgentPicker.new() |> AgentPicker.open() |> AgentPicker.toggle("agent-b")

    applied = AgentPicker.apply(state)
    assert applied.committed == MapSet.new(["agent-a", "agent-b"])

    cancelled = applied |> AgentPicker.remove("agent-a") |> AgentPicker.cancel()
    assert cancelled.draft == MapSet.new(["agent-a", "agent-b"])

    cleared = cancelled |> AgentPicker.clear() |> AgentPicker.apply()
    assert cleared.draft == MapSet.new()
    assert cleared.committed == MapSet.new()
  end

  test "preserves a draft selection and its count after a retryable query failure" do
    state = ["agent-a"] |> AgentPicker.new() |> AgentPicker.open() |> AgentPicker.toggle("agent-b")

    failed = AgentPicker.loaded(state, {:error, :timeout})

    assert failed.draft == MapSet.new(["agent-a", "agent-b"])
    assert MapSet.size(failed.draft) == 2
    assert %{reason: :timeout, retryable?: true} = failed.error
  end
end
