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
end
