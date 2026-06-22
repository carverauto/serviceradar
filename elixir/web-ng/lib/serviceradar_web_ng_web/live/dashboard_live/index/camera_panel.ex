defmodule ServiceRadarWebNGWeb.DashboardLive.Index.CameraPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DashboardLive.Index.Common

  alias ServiceRadarWebNGWeb.CameraRelayComponents
  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <Common.panel
      :if={camera_panel_visible?(@camera_summary)}
      title="Camera Operations"
      class="lg:col-span-6"
    >
      <:actions>
        <.link href={~p"/cameras"} class="sr-ops-button">
          View All Cameras
        </.link>
      </:actions>
      <div class="sr-ops-camera-operations" data-testid="camera-operations">
        <div class="sr-ops-camera-status-list">
          <.camera_status_row
            label="Available"
            value={to_string(@camera_summary.online)}
            icon="hero-video-camera"
            tone="success"
          />
          <.camera_status_row
            label="Offline"
            value={to_string(@camera_summary.offline)}
            icon="hero-video-camera-slash"
            tone="error"
          />
          <.camera_status_row
            label="Recording"
            value={to_string(@camera_summary.recording)}
            icon="hero-camera"
            tone="info"
          />
          <.camera_status_row
            label="Total Cameras"
            value={to_string(@camera_summary.total)}
            icon="hero-squares-2x2"
            tone="neutral"
          />
        </div>
        <div class="sr-ops-camera-wall">
          <.link
            :for={tile <- @camera_preview_tiles}
            href={~p"/cameras/#{tile.camera_source_id}"}
            class="sr-ops-camera-tile sr-ops-camera-tile-live"
            aria-label={"Open #{tile.label}"}
          >
            <CameraRelayComponents.relay_player
              :if={tile.session}
              session={tile.session}
              id_prefix="dashboard-camera-relay"
            />
            <div :if={!tile.session} class="sr-ops-camera-tile-error">
              <.icon name="hero-video-camera-slash" class="size-6" />
              <span>{tile.error || "Relay unavailable"}</span>
            </div>
            <div class="sr-ops-camera-tile-caption">
              <span>
                <i class={camera_status_dot_class(tile.source_status)}></i>{tile.label}
              </span>
              <small>{camera_preview_detail(tile)}</small>
            </div>
          </.link>
          <.link
            :for={tile <- camera_tiles(@camera_summary.tiles, @camera_preview_tiles)}
            href={camera_tile_href(tile)}
            class="sr-ops-camera-tile"
            aria-label={"Open #{tile.label}"}
          >
            <div class="sr-ops-camera-thumbnail" aria-hidden="true">
              <.icon name="hero-video-camera" class="size-7" />
            </div>
            <div class="sr-ops-camera-tile-caption">
              <span><i class={camera_status_dot_class(tile.status)}></i>{tile.label}</span>
              <small>{camera_status_label(tile.status)}</small>
            </div>
          </.link>
        </div>
      </div>
    </Common.panel>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:tone, :string, default: "neutral")

  defp camera_status_row(assigns) do
    ~H"""
    <div class={["sr-ops-camera-status-row", "tone-#{@tone}"]}>
      <span>
        <.icon name={@icon} class="size-4" />
        {@label}
      </span>
      <strong>{@value}</strong>
    </div>
    """
  end

  defp camera_tiles(tiles, preview_tiles) do
    remaining = max(4 - length(preview_tiles), 0)
    preview_ids = MapSet.new(preview_tiles, &camera_tile_id/1)

    visible_tiles =
      tiles
      |> List.wrap()
      |> Enum.reject(&(camera_tile_id(&1) in preview_ids))
      |> Enum.take(remaining)

    visible_tiles ++ camera_placeholder_tiles(remaining - length(visible_tiles))
  end

  defp camera_placeholder_tiles(count) when count > 0 do
    Enum.map(1..count, fn index ->
      %{id: nil, label: "No preview", status: "empty", slot: index}
    end)
  end

  defp camera_placeholder_tiles(_count), do: []

  defp camera_tile_href(%{id: id}) when is_binary(id) and id != "", do: ~p"/cameras/#{id}"
  defp camera_tile_href(_tile), do: ~p"/cameras"

  defp camera_tile_id(%{camera_source_id: id}) when is_binary(id), do: id
  defp camera_tile_id(%{id: id}) when is_binary(id), do: id
  defp camera_tile_id(_tile), do: nil

  defp camera_status_label(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      status when status in ["available", "online", "active", "healthy"] -> "Online"
      status when status in ["offline", "unavailable", "failed", "error"] -> "Offline"
      "empty" -> "No relay"
      "" -> "Unknown"
      status -> String.capitalize(status)
    end
  end

  defp camera_preview_detail(%{session: session, detail: detail}) when not is_nil(session), do: detail

  defp camera_preview_detail(%{error: error}) when is_binary(error) and error != "" do
    cond do
      String.contains?(error, "Assigned agent") and String.contains?(error, "offline") ->
        "Agent offline"

      String.contains?(error, "No relay-capable") ->
        "No relay profile"

      true ->
        error
    end
  end

  defp camera_preview_detail(_tile), do: "No relay"

  defp camera_status_dot_class(value) do
    case camera_status_label(value) do
      "Online" -> "is-online"
      "Offline" -> "is-offline"
      _ -> "is-unknown"
    end
  end
end
