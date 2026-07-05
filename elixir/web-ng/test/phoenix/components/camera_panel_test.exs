defmodule ServiceRadarWebNGWeb.Components.CameraPanelTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DashboardLive.Index.CameraPanel

  @moduletag :unit
  @moduletag :db_free

  setup do
    # The panel links through verified routes, which resolve against the
    # running endpoint. In db-free runs the application is not started, so
    # start the endpoint supervised for the test.
    if is_nil(Process.whereis(ServiceRadarWebNGWeb.Endpoint)) do
      start_supervised!(ServiceRadarWebNGWeb.Endpoint)
    end

    :ok
  end

  defp render_panel(camera_summary, camera_preview_tiles) do
    render_component(&CameraPanel.render/1, %{
      dashboard: %{
        camera_summary: camera_summary,
        camera_preview_tiles: camera_preview_tiles
      }
    })
  end

  defp summary(attrs) do
    Map.merge(%{total: 0, online: 0, offline: 0, recording: 0, tiles: []}, attrs)
  end

  defp preview_tile(attrs) do
    Map.merge(
      %{
        camera_source_id: Ecto.UUID.generate(),
        stream_profile_id: Ecto.UUID.generate(),
        label: "Camera",
        detail: "Primary stream",
        source_status: "available",
        session: nil,
        error: nil
      },
      attrs
    )
  end

  describe "available but not streamable" do
    test "renders the combined degraded state with the blocking reason and split summary counts" do
      html =
        render_panel(
          summary(%{
            total: 2,
            online: 2,
            tiles: [
              %{id: "cam-front", label: "Front Door", status: "available"},
              %{id: "cam-back", label: "Back Yard", status: "available"}
            ]
          }),
          [
            preview_tile(%{
              camera_source_id: "cam-front",
              label: "Front Door",
              error: "Assigned agent agent-sr-test-pve04 is offline"
            })
          ]
        )

      # Split summary dimensions: inventory availability vs live stream operability.
      assert html =~ "Available"
      assert html =~ "Streamable"
      assert row_value(html, "Available") == "2"
      assert row_value(html, "Streamable") == "0"

      # The green Available count is never left silently contradicting the tiles.
      assert html =~ "tone-warning"
      assert html =~ "not streamable"

      # Degraded tile carries the combined state with the blocking reason.
      assert html =~ "available, not streamable — agent offline"

      # Un-previewed available cameras are reported as unchecked, not implied OK.
      assert html =~ "1 blocked · 1 unchecked"

      # Provenance of each number is inspectable.
      assert html =~ "Source: inventory (camera source availability status)"
      assert html =~ "Source: live relay (preview stream resolution)"
      assert html =~ "Source: live relay (active relay sessions)"
    end

    test "cameras beyond the previewed tiles read as stream-unchecked, not online" do
      html =
        render_panel(
          summary(%{
            total: 1,
            online: 1,
            tiles: [%{id: "cam-side", label: "Side Gate", status: "available"}]
          }),
          []
        )

      assert html =~ "Available · stream unchecked"
      refute html =~ ">Online<"
      assert row_value(html, "Streamable") == "0"
      assert html =~ "1 unchecked"
      # No relay resolution failed, so nothing is contradicted.
      refute html =~ "tone-warning"
    end
  end

  describe "fully operational camera" do
    test "renders without any degraded qualifier" do
      session_id = Ecto.UUID.generate()

      html =
        render_panel(
          summary(%{
            total: 1,
            online: 1,
            recording: 1,
            tiles: [%{id: "cam-front", label: "Front Door", status: "available"}]
          }),
          [
            preview_tile(%{
              camera_source_id: "cam-front",
              label: "Front Door",
              detail: "Low",
              session: %{id: session_id, status: :active, media_ingest_id: "ingest-1"}
            })
          ]
        )

      assert row_value(html, "Available") == "1"
      assert row_value(html, "Streamable") == "1"

      refute html =~ "not streamable"
      refute html =~ "tone-warning"
      refute html =~ "blocked"
      refute html =~ "unchecked"
      refute html =~ "sr-ops-camera-tile-degraded"

      # The streaming tile keeps its plain stream detail.
      assert html =~ "Low"
      assert html =~ "Source: live relay (stream open)"
    end
  end

  # Extracts the <strong> value of the summary row with the given label.
  defp row_value(html, label) do
    case Regex.run(
           ~r/#{Regex.escape(label)}\s*(?:<small[^>]*>.*?<\/small>)?\s*<\/span>\s*<strong>([^<]*)<\/strong>/s,
           html
         ) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end
end
