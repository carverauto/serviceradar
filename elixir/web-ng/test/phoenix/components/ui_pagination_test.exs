defmodule ServiceRadarWebNGWeb.Components.UIPaginationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.UIComponents

  @moduletag :db_free

  test "first-page control is available on page 2 even without a prev cursor" do
    html =
      render_component(&UIComponents.ui_pagination/1, %{
        prev_cursor: nil,
        next_cursor: "cursor-page-3",
        current_page: 2,
        result_count: 20,
        total_count: 40,
        limit: 20
      })

    assert html =~ "First page"
    assert html =~ ~s(phx-value-page="1")
    assert html =~ ~s(title="First page")
    refute html =~ ~r/title="First page"[^>]*phx-value-cursor/
  end

  test "first-page control is hidden on page 1" do
    html =
      render_component(&UIComponents.ui_pagination/1, %{
        prev_cursor: nil,
        next_cursor: "cursor-page-2",
        current_page: 1,
        result_count: 20,
        total_count: 40,
        limit: 20
      })

    refute html =~ "First page"
  end
end
