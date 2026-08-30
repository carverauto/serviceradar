defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.AgentPickerComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Live.Settings.NetworksLive.AgentPicker
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.AgentPickerComponents

  @moduletag :db_free

  test "browse modal is accessible and never renders more than fifty agent rows" do
    results =
      for index <- 1..51 do
        %{uid: "agent-#{index}", name: "Agent #{index}", status: :connected, capabilities: ["sweep"]}
      end

    state =
      []
      |> AgentPicker.new()
      |> AgentPicker.open()
      |> AgentPicker.loaded(%{results: results, before: nil, after: "next"})

    html =
      render_component(&AgentPickerComponents.agent_picker_modal/1,
        state: state,
        open: true,
        selected_rows: []
      )

    document = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.query("#sweep-agent-picker-dialog[data-return-focus='#sweep-agent-picker-trigger']")
           |> LazyHTML.to_tree() != []

    assert document
           |> LazyHTML.query("#sweep-agent-picker-search[data-dialog-autofocus]")
           |> LazyHTML.to_tree() != []

    assert document
           |> LazyHTML.query("#sweep-agent-picker-selected-count[aria-live='polite']")
           |> LazyHTML.to_tree() != []

    assert document
           |> LazyHTML.query("[data-agent-picker-row]")
           |> LazyHTML.to_tree()
           |> length() == 50

    assert document
           |> LazyHTML.query("button[aria-label='Next agents page']:not([disabled])")
           |> LazyHTML.to_tree() != []

    assert document
           |> LazyHTML.query("button[aria-label='Previous agents page'][disabled]")
           |> LazyHTML.to_tree() != []
  end

  test "assignment fields derive hidden IDs from committed state and keep multi-selection count-only" do
    state = ["agent-b", "agent-a"] |> AgentPicker.new() |> AgentPicker.toggle("agent-draft")

    html =
      render_component(&AgentPickerComponents.agent_assignment_fields/1,
        state: state,
        summary_agent: nil
      )

    document = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.query("input[name='form[agent_ids][]'][value='agent-a']")
           |> LazyHTML.to_tree() != []

    assert document
           |> LazyHTML.query("input[name='form[agent_ids][]'][value='agent-b']")
           |> LazyHTML.to_tree() != []

    assert document
           |> LazyHTML.query("input[name='form[agent_ids][]'][value='agent-draft']")
           |> LazyHTML.to_tree() == []

    assert LazyHTML.text(document) =~ "2 selected agents"
    refute LazyHTML.text(document) =~ "Unavailable"
  end

  test "selected mode renders stale IDs as removable unavailable rows" do
    state =
      ["agent-known", "agent-stale"]
      |> AgentPicker.new()
      |> AgentPicker.open()
      |> AgentPicker.show_selected()

    html =
      render_component(&AgentPickerComponents.agent_picker_modal/1,
        state: state,
        open: true,
        selected_rows: [
          %{uid: "agent-known", agent: %{uid: "agent-known", name: "Known agent", status: :connected}},
          %{uid: "agent-stale", agent: nil}
        ]
      )

    document = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.query("[data-agent-picker-uid='agent-stale'][data-agent-unavailable]")
           |> LazyHTML.to_tree() != []

    assert document
           |> LazyHTML.query("button[phx-click='agent_picker_remove'][phx-value-uid='agent-stale']")
           |> LazyHTML.to_tree() != []
  end
end
