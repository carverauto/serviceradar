defmodule ServiceRadarWebNGWeb.Components.MtrProfilesLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Settings.MtrProfilesLive.Index

  @moduletag :db_free

  test "profile form submits the displayed SRQL query under the selector key" do
    target_query = "in:devices include_inactive:true tags.rids:true"

    form =
      Phoenix.Component.to_form(
        %{
          "name" => "RIDS",
          "srql_query" => target_query
        },
        as: :form
      )

    document =
      (&Index.profile_form/1)
      |> render_component(
        form: form,
        show_form: :new_profile,
        selected_profile: nil,
        target_scope_summary: nil,
        builder_open: false,
        builder: %{"filters" => []},
        builder_sync: true,
        agents: [],
        bulk_interval_guidance: nil
      )
      |> LazyHTML.from_fragment()

    editor = LazyHTML.query(document, "#mtr-profile-target-query-editor")

    assert LazyHTML.attribute(editor, "name") == ["form[srql_query]"]
    assert LazyHTML.attribute(editor, "value") == [target_query]
    assert document |> LazyHTML.query("#mtr-profile-form") |> LazyHTML.to_tree() != []
  end

  # Regression: the selector-limit input was bound to :selector_limit while every
  # reader used @selector_limit_key ("limit"). That mismatch broke the field in
  # both directions at once -- it rendered blank whatever was persisted, and
  # submitted nothing, so parse_int/3 fell through to its 100 default and the
  # limit could never be moved off 100 from the UI. Assert the round trip.
  test "profile form round-trips the selector limit under the selector key" do
    form =
      Phoenix.Component.to_form(
        %{
          "name" => "Kiosks",
          "srql_query" => "in:devices include_inactive:true tags.kiosk:true",
          "limit" => 250
        },
        as: :form
      )

    document =
      (&Index.profile_form/1)
      |> render_component(
        form: form,
        show_form: :new_profile,
        selected_profile: nil,
        target_scope_summary: nil,
        builder_open: false,
        builder: %{"filters" => []},
        builder_sync: true,
        agents: [],
        bulk_interval_guidance: nil
      )
      |> LazyHTML.from_fragment()

    limit_input = LazyHTML.query(document, "#mtr-profile-selector-limit")

    # The name decides where a submit lands; save_profile/2 reads params["limit"].
    assert LazyHTML.attribute(limit_input, "name") == ["form[limit]"]
    # The value decides whether a persisted limit is visible for editing.
    assert LazyHTML.attribute(limit_input, "value") == ["250"]
  end
end
