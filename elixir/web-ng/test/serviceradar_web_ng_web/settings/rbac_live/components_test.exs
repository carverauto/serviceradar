defmodule ServiceRadarWebNGWeb.Settings.RbacLive.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.AsyncResult
  alias ServiceRadarWebNGWeb.Settings.RbacLive.Components

  @moduletag :db_free

  test "loading state renders a stable marker" do
    html = render_component(&Components.group_profile_controls/1, result: AsyncResult.loading())

    assert html
           |> document()
           |> LazyHTML.query("#rbac-group-profile-loading[data-state='loading']")
           |> present?()
  end

  test "empty state is distinct from a load failure" do
    result =
      AsyncResult.ok(AsyncResult.loading(), %{
        generation: 1,
        groups: [],
        profiles: [],
        group_tokens: %{},
        profile_tokens: %{}
      })

    html = render_component(&Components.group_profile_controls/1, result: result)
    page = document(html)

    assert present?(LazyHTML.query(page, "#rbac-group-profile-empty[data-state='empty']"))
    refute LazyHTML.text(page) =~ "Unable to load user groups. Try again."
  end

  test "success state renders only opaque values for assign and clear events" do
    raw_group_id = "33333333-3333-4333-8333-333333333333"
    raw_profile_id = "44444444-4444-4444-8444-444444444444"

    result =
      AsyncResult.ok(AsyncResult.loading(), %{
        generation: 2,
        groups: [
          %{
            id: raw_group_id,
            name: "Synthetic responders",
            description: "Invented group",
            role_profile_id: raw_profile_id
          }
        ],
        profiles: [%{id: raw_profile_id, name: "Synthetic response policy", system: false}],
        group_tokens: %{"opaque-group-token" => raw_group_id},
        profile_tokens: %{"opaque-profile-token" => raw_profile_id}
      })

    html = render_component(&Components.group_profile_controls/1, result: result)
    page = document(html)

    assert present?(LazyHTML.query(page, "#rbac-group-profile-controls[data-state='success']"))

    assert LazyHTML.attribute(
             LazyHTML.query(page, "form[phx-change='assign_group_profile'] input"),
             "value"
           ) ==
             ["opaque-group-token"]

    assert LazyHTML.attribute(LazyHTML.query(page, "option[selected]"), "value") ==
             ["opaque-profile-token"]

    assert LazyHTML.attribute(
             LazyHTML.query(page, "button[phx-click='clear_group_profile']"),
             "phx-value-group-token"
           ) == ["opaque-group-token"]

    refute html =~ raw_group_id
    refute html =~ raw_profile_id
  end

  test "failure state renders the exact generic retry message and omits the reason" do
    marker = "internal-query-marker-must-stay-server-side"
    result = AsyncResult.failed(AsyncResult.loading(), {:error, {:groups, marker}})

    html = render_component(&Components.group_profile_controls/1, result: result)
    page = document(html)

    assert present?(
             LazyHTML.query(page, "#rbac-group-profile-error[data-state='error'][role='alert']")
           )

    assert LazyHTML.text(page) =~ "Unable to load user groups. Try again."
    assert present?(LazyHTML.query(page, "button[phx-click='retry_group_profiles']"))
    refute html =~ marker
    refute LazyHTML.text(page) =~ "No user groups"
  end

  defp document(html), do: LazyHTML.from_fragment(html)
  defp present?(selection), do: LazyHTML.to_tree(selection) != []
end
