defmodule ServiceRadarWebNGWeb.LayoutsTopbarActionsTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Layouts

  @moduletag :unit
  @moduletag :db_free

  test "operations shell renders page actions in the topbar, not over page content" do
    html = render_component(&preview/1, %{})

    assert html =~ ~s(id="ops-topbar")
    assert html =~ ~s(id="dashboard-package-share-button")
    assert html =~ ~s(id="dashboard-package-host")
    refute html =~ "absolute right-4 top-4 z-20"

    [_prefix, rest] = String.split(html, ~s(id="ops-topbar"), parts: 2)
    [topbar_html, body_html] = String.split(rest, ~s(id="dashboard-package-host"), parts: 2)

    assert topbar_html =~ "dashboard-package-share-button"
    refute body_html =~ "dashboard-package-share-button"
  end

  test "operations profile menu preserves native details open state across LiveView patches" do
    html = render_component(&preview/1, %{})

    assert html =~ ~s(id="ops-profile-menu")
    assert html =~ ~s(phx-hook="DetailsState")

    [_prefix, menu_html] = String.split(html, ~s(id="ops-profile-menu"), parts: 2)
    [summary_html, _rest] = String.split(menu_html, "</summary>", parts: 2)

    assert summary_html =~ "pointer-events-none"
  end

  defp preview(assigns) do
    ~H"""
    <Layouts.app
      flash={%{}}
      current_scope={%{user: %{id: "u1", email: "owner@example.test", role: :admin}}}
      current_path="/dashboards/rids"
      page_title="RIDS Displays"
      shell={:operations}
      hide_breadcrumb
      srql={%{}}
    >
      <:topbar_actions>
        <button id="dashboard-package-share-button" type="button">Share</button>
      </:topbar_actions>
      <section id="dashboard-package-host">
        <button type="button">Gates</button>
      </section>
    </Layouts.app>
    """
  end
end
