defmodule ServiceRadarWebNGWeb.Flows.AttributedLiveTest do
  @moduledoc """
  Attributed flows on an installation without the StarRocks warehouse.

  Flow attribution reads are warehouse-only: `in:attributed_flows` answers
  `{:error, :starrocks_required}` when StarRocks is disabled, and the page must
  render its honest empty state rather than crash.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  @moduletag :web_ng_shared_fixture_db

  # Endpoints used as negative-control assertions.
  @cnpg_attributed_endpoint "192.0.2.41:24001"
  @cnpg_unmatched_endpoint "192.0.2.43:24003"

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{conn: log_in_user(conn, user)}
  end

  test "default view reports no attributed flows without the warehouse", %{conn: conn} do
    {view, _html, log} = live_settled(conn, ~p"/observability/flows/attributed")

    assert log =~ "Attributed flow SRQL rows query failed: :starrocks_required"
    assert log =~ "Attributed flow SRQL summary query failed: :starrocks_required"
    assert has_element?(view, "div", "No attributed flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows", @cnpg_attributed_endpoint)
    refute has_element?(view, "#attributed-flows button")
  end

  test "unmatched filter shows its empty state, not CNPG rows", %{conn: conn} do
    {view, _html, log} = live_settled(conn, ~p"/observability/flows/attributed?#{%{filter: "unmatched"}}")

    assert log =~ ":starrocks_required"
    assert has_element?(view, "div", "No unmatched flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows", @cnpg_unmatched_endpoint)
  end

  test "stat cards still switch filters without losing LiveView context", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed")
    settle(view)

    view
    |> element("button[phx-value-filter='unmatched']", "Unmatched")
    |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "unmatched", page: 1, per_page: 50}}")
    settle(view)
    assert has_element?(view, "div", "No unmatched flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows", @cnpg_unmatched_endpoint)

    view
    |> element("button[phx-value-filter='all']", "Rows")
    |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "all", page: 1, per_page: 50}}")
    settle(view)
    assert has_element?(view, "div", "No attributed or unmatched flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows button")
  end

  test "live toggle can be disabled and re-enabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed")
    settle(view)

    assert has_element?(view, "button[phx-click='toggle_live']", "Off")

    view |> element("button[phx-click='toggle_live']") |> render_click()

    assert has_element?(view, "button[phx-click='toggle_live']", "On")

    view |> element("button[phx-click='toggle_live']") |> render_click()

    assert has_element?(view, "button[phx-click='toggle_live']", "Off")
  end

  test "live toggle from a later page returns to the first page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/observability/flows/attributed?#{%{per_page: 1}}")
    settle(view)

    render_click(view, "goto_page", %{"page" => "2"})
    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "attributed", page: 2, per_page: 1}}")
    settle(view)

    view |> element("button[phx-click='toggle_live']") |> render_click()

    assert_patch(view, ~p"/observability/flows/attributed?#{%{filter: "attributed", page: 1, per_page: 1}}")

    settle(view)
    assert has_element?(view, "button[phx-click='toggle_live']", "On")
    assert has_element?(view, "div", "Page 1 of 1.")
    refute has_element?(view, "#attributed-flows button")
  end

  test "all rows view renders no protocol rows from CNPG", %{conn: conn} do
    {view, _html, log} = live_settled(conn, ~p"/observability/flows/attributed?#{%{filter: "all"}}")

    assert log =~ ":starrocks_required"
    assert has_element?(view, "div", "No attributed or unmatched flows in last 24 hours.")
    refute has_element?(view, "#attributed-flows", @cnpg_attributed_endpoint)
    refute has_element?(view, "#attributed-flows", @cnpg_unmatched_endpoint)
    refute has_element?(view, "#attributed-flows button")
  end

  # Mounts the page and waits for its async flow load (start_async) to finish,
  # returning the rendered page and the warnings logged meanwhile. The capture
  # spans the mount because the load starts there. render_async/2 raises if the
  # LiveView crashed.
  defp live_settled(conn, path) do
    {{view, html}, log} =
      with_log([level: :warning], fn ->
        {:ok, view, _html} = live(conn, path)
        {view, render_async(view, 10_000)}
      end)

    {view, html, log}
  end

  # Waits for the async load started by the latest navigation; raises if the
  # LiveView crashed.
  defp settle(view), do: render_async(view, 10_000)
end
