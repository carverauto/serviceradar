defmodule ServiceRadarWebNG.CameraRelayHealthTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelayHealthEventRouter
  alias ServiceRadarWebNG.CameraRelayHealth
  alias ServiceRadarWebNGWeb.CameraRelayLive.Index, as: CameraRelayLiveIndex

  @moduletag :db_free

  describe "recent_events_query/3" do
    test "pushes relay health log_name filter and bounded 7-day time cutoff into Ash query" do
      now = ~U[2026-11-27 12:00:00Z]

      query = CameraRelayHealth.recent_events_query(nil, 6, now: now)
      filter_text = inspect(query.filter)

      assert query.limit == 6
      assert query.sort == [time: :desc]

      for log_name <- RelayHealthEventRouter.relay_health_log_names() do
        assert filter_text =~ log_name
      end

      assert filter_text =~ "log_name in"
      assert filter_text =~ "time >= ~U[2026-11-20 12:00:00.000000Z]"
    end
  end

  describe "CameraRelayLive.Index.handle_params/3" do
    test "skips load_sessions during disconnected mount" do
      socket = %Phoenix.LiveView.Socket{
        transport_pid: nil,
        assigns: %{
          __changed__: %{},
          current_scope: nil,
          filters: %{active: "all", terminal: "all"},
          active_sessions: [],
          terminal_sessions: [],
          refreshed_at: nil
        }
      }

      assert {:noreply, updated} =
               CameraRelayLiveIndex.handle_params(
                 %{"active" => "opening", "terminal" => "failed"},
                 "http://localhost/observability/camera-relays",
                 socket
               )

      assert updated.assigns.filters == %{active: "opening", terminal: "failed"}
      assert updated.assigns.refreshed_at == nil
      assert updated.assigns.active_sessions == []
    end
  end
end
