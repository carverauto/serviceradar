defmodule ServiceRadarWebNGWeb.DashboardLive.EventsRangeNavigationTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.DashboardLive.Index

  @moduletag :db_free

  test "navigates to the fixed Events intent path for an exact ordered range" do
    params = %{
      "start" => "2026-08-27T10:00:00Z",
      "end" => "2026-08-27T12:59:59.999999Z"
    }

    assert {:noreply,
            %Socket{
              redirected:
                {:live, :redirect,
                 %{
                   to:
                     "/observability/events?q=in%3Aevents+time%3A%5B2026-08-27T10%3A00%3A00Z%2C2026-08-27T12%3A59%3A59.999999Z%5D+sort%3Atime%3Adesc+limit%3A20",
                   kind: :push
                 }}
            }} = Index.handle_event("select_events_range", params, socket())
  end

  test "does not navigate for malformed, equal, reversed, non-rendered, stale, or out-of-window range params" do
    for params <- [
          %{"start" => "bad", "end" => "2026-08-27T12:59:59.999999Z"},
          %{"start" => "2026-08-27T10:00:00Z", "end" => "2026-08-27T10:00:00Z"},
          %{"start" => "2026-08-27T12:00:00Z", "end" => "2026-08-27T10:59:59.999999Z"},
          %{"start" => "2026-08-27T10:30:00Z", "end" => "2026-08-27T12:59:59.999999Z"},
          %{"start" => "2026-08-27T09:00:00Z", "end" => "2026-08-27T09:59:59.999999Z"},
          %{"start" => "2026-08-27T14:00:00Z", "end" => "2026-08-27T14:59:59.999999Z"}
        ] do
      assert {:noreply, %Socket{redirected: nil}} =
               Index.handle_event("select_events_range", params, socket())
    end
  end

  defp socket do
    %Socket{
      assigns: %{
        __changed__: %{},
        security_trend: [
          %{bucket: ~U[2026-08-27 10:00:00Z]},
          %{bucket: ~N[2026-08-27 12:00:00]},
          %{bucket: ~U[2026-08-27 13:00:00Z]}
        ]
      },
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end
end
