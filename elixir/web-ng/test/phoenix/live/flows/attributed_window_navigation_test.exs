defmodule ServiceRadarWebNGWeb.Flows.AttributedWindowNavigationTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.Flows.AttributedLive

  @moduletag :db_free

  test "preset windows rewrite the attributed query and reset to page 1" do
    socket =
      socket(%{
        srql: %{query: "in:attributed_flows time:last_24h attribution_status:attributed sort:time:desc limit:50"},
        filter: "attributed",
        page: 2,
        page_size: 50
      })

    assert {:noreply, result} = AttributedLive.handle_event("attributed_set_range", %{"range" => "last_7d"}, socket)
    params = redirected_query(result)
    assert params["filter"] == "attributed"
    assert params["page"] == "1"
    assert params["q"] == "in:attributed_flows attribution_status:attributed sort:time:desc limit:50 time:last_7d"
    assert {:noreply, ^socket} = AttributedLive.handle_event("attributed_set_range", %{"range" => "all"}, socket)
  end

  test "custom UTC range becomes an absolute SRQL time token" do
    socket =
      socket(%{
        srql: %{query: "in:attributed_flows time:last_24h sort:time:desc limit:50"},
        filter: "all",
        page: 1,
        page_size: 50
      })

    params = %{"window" => %{"start" => "2025-01-01T00:00", "end" => "2025-04-01T00:00"}}
    assert {:noreply, result} = AttributedLive.handle_event("attributed_custom_range", params, socket)
    params = redirected_query(result)
    assert params["q"] == "in:attributed_flows sort:time:desc limit:50 time:[2025-01-01T00:00:00Z,2025-04-01T00:00:00Z]"
  end

  defp redirected_query(%Socket{
         redirected: {:live, :patch, %{to: "/observability/flows/attributed?" <> query, kind: :push}}
       }) do
    URI.decode_query(query)
  end

  defp socket(overrides) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          filter: "attributed",
          page: 1,
          page_size: 50,
          srql: %{query: "in:attributed_flows time:last_24h sort:time:desc limit:50"}
        },
        overrides
      )

    %Socket{
      assigns: assigns,
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end
end
