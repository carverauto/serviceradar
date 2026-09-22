defmodule ServiceRadarWebNGWeb.Components.BulkEditModalTest do
  @moduledoc false

  # async: false because the component renders the shared endpoint-warmed
  # primitives; see the tier note in test/test_helper.exs. The :db_free tag is
  # mandatory -- without it this file is loaded by the shard and silently
  # contributes zero tests.
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Helpers
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.BulkModals

  @moduletag :unit
  @moduletag :db_free

  setup_all do
    case start_supervised(ServiceRadarWebNGWeb.Endpoint) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "keeps the tag form and adds service, managed and scoped state controls" do
    html =
      render_modal(
        srql: %{query: "in:devices hostname:%host01%"},
        total_matching_count: 42
      )

    # The existing tag behaviour is untouched: the same form and submit event.
    assert html =~ ~s(id="bulk-tags-form")
    assert html =~ ~s(phx-submit="apply_bulk_tags")

    # New state form with its own submit event and field ids.
    assert html =~ ~s(id="bulk-state-form")
    assert html =~ ~s(phx-submit="apply_bulk_state")
    assert html =~ ~s(id="bulk-state-service")
    assert html =~ ~s(id="bulk-state-managed")
    assert html =~ ~s(id="bulk-state-scope")
    assert html =~ "Out of service (inactive)"
    assert html =~ "Unmanaged"

    # Scope offers the paginated selection and, with a filter present, the
    # whole result set with its materialised count.
    assert html =~ "Selected (7)"
    assert html =~ "All 42 matching"
  end

  test "the scope control is its own form so it governs the tag submit too" do
    html =
      render_modal(
        srql: %{query: "in:devices hostname:%host01%"},
        total_matching_count: 42
      )

    # Scope reports on change into socket state (select_all_matching), which is
    # what Selection.selected_uids/1 resolves targets from -- so the tag submit
    # honours the same choice. It must NOT ride along with the state submit, or
    # picking "All matching" would silently apply tags to the toolbar selection.
    assert html =~ ~s(id="bulk-scope-form")
    assert html =~ ~s(phx-change="bulk_state_scope_change")
    assert html =~ ~s(name="bulk_scope[scope]")
    refute html =~ ~s(name="bulk_state[scope]")
  end

  test "only offers all-matching when the query actually carries a filter" do
    html = render_modal(srql: %{query: ""}, total_matching_count: nil)

    assert html =~ "Selected (7)"
    refute html =~ "all_matching"
    refute html =~ "All matching"
  end

  defp render_modal(overrides) do
    assigns =
      Map.merge(
        %{
          form: to_form(%{"tags" => ""}, as: :bulk),
          state_form: Helpers.bulk_state_form(),
          scope_form: Helpers.bulk_scope_form(),
          selected_count: 7,
          total_matching_count: nil,
          select_all_matching: false,
          srql: %{query: ""}
        },
        Map.new(overrides)
      )

    render_component(&BulkModals.bulk_edit_modal/1, assigns)
  end
end
