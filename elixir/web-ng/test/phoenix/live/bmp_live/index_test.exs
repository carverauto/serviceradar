defmodule ServiceRadarWebNGWeb.BmpLive.IndexTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.TestSupport.BmpLoadingSRQLStub

  @moduletag :web_ng_shared_fixture_db

  setup :register_and_log_in_user

  setup do
    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, BmpLoadingSRQLStub)

    on_exit(fn ->
      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)
  end

  test "routing list renders loading then streamed rows without a manual run", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/observability/bmp")

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("#bmp-tab-loading[role='status']") |> Enum.any?()
    assert has_element?(view, "#bmp-event-route-a", "192.0.2.1")
    assert has_element?(view, "#bmp-tab-content:not([hidden])")
    refute has_element?(view, "#bmp-tab-loading")

    render_patch(view, ~p"/observability/bmp?#{%{q: "in:bmp_events event_type:peer_up"}}")

    assert has_element?(view, "#bmp-event-peer-a", "192.0.2.2")
    assert has_element?(view, "#bmp-tab-content:not([hidden])")
    refute has_element?(view, "#bmp-event-route-a")
    refute has_element?(view, "#bmp-tab-loading")
  end
end
