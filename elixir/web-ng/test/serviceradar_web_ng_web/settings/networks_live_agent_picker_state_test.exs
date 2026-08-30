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
    assert reset.draft == MapSet.new(["agent-a", "agent-b"])
    assert %{search: "another query", selector: :first} = AgentPicker.browse_request(reset)

    retained =
      reset
      |> AgentPicker.loaded(%{results: [%{uid: "agent-c"}], after: nil, before: nil})
      |> AgentPicker.toggle("agent-c")

    assert retained.draft == MapSet.new(["agent-a", "agent-b", "agent-c"])
  end

  test "owns selected pagination boundaries and clamps the offset after removal" do
    ids = for index <- 1..101, do: "agent-#{String.pad_leading(Integer.to_string(102 - index), 3, "0")}"

    state = ids |> AgentPicker.new() |> AgentPicker.open() |> AgentPicker.show_selected()

    assert :selected == state.mode

    assert %{
             uids: first_page,
             count: 101,
             offset: 0,
             has_previous?: false,
             has_next?: true
           } = AgentPicker.selected_page(state)

    assert first_page == ids |> Enum.sort() |> Enum.take(50)
    assert AgentPicker.selected_previous_page(state) == state

    second = AgentPicker.selected_next_page(state)

    assert %{
             uids: second_page,
             offset: 50,
             has_previous?: true,
             has_next?: true
           } = AgentPicker.selected_page(second)

    assert length(second_page) == 50

    last = AgentPicker.selected_next_page(second)

    assert %{
             uids: [last_uid],
             offset: 100,
             has_previous?: true,
             has_next?: false
           } = AgentPicker.selected_page(last)

    assert AgentPicker.selected_next_page(last) == last

    clamped = AgentPicker.remove(last, last_uid)

    assert %{offset: 50, has_next?: false} = AgentPicker.selected_page(clamped)
    assert AgentPicker.selected_previous_page(clamped).selected_offset == 0
    assert :browse == AgentPicker.show_browse(clamped).mode
  end

  test "keeps selected lookup errors distinct from proven unavailable UIDs and supports retry" do
    state = ["agent-a", "agent-stale"] |> AgentPicker.new() |> AgentPicker.open() |> AgentPicker.show_selected()

    failed = AgentPicker.selected_loaded(state, {:error, :timeout})

    assert failed.error == nil
    assert %{reason: :timeout, retryable?: true} = failed.selected_error
    assert %{uids: ["agent-a", "agent-stale"], count: 2, offset: 0} = AgentPicker.selected_page(failed)

    retried = AgentPicker.selected_loaded(failed, :ok)
    assert retried.selected_error == nil
    assert %{uids: ["agent-a", "agent-stale"], count: 2} = AgentPicker.selected_page(retried)
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
