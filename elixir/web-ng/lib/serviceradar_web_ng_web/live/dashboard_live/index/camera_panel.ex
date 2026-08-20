defmodule ServiceRadarWebNGWeb.DashboardLive.Index.CameraPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DashboardLive.Index.Common

  alias ServiceRadarWebNGWeb.CameraRelayComponents
  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  @inventory_available_statuses ["available", "online", "active", "healthy"]
  @inventory_offline_statuses ["offline", "unavailable", "failed", "error"]

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    assigns =
      Map.put(
        assigns,
        :camera_stream_health,
        camera_stream_health(assigns.camera_summary, assigns[:camera_preview_tiles])
      )

    ~H"""
    <Common.panel
      :if={camera_panel_visible?(@camera_summary)}
      title="Camera Operations"
      class="sr-ops-camera-panel"
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
            tone={if @camera_stream_health.contradicted, do: "warning", else: "success"}
            detail={if @camera_stream_health.contradicted, do: "not streamable", else: nil}
            provenance="Source: inventory (camera source availability status)"
          />
          <.camera_status_row
            label="Streamable"
            value={to_string(@camera_stream_health.streamable)}
            icon="hero-signal"
            tone={streamable_tone(@camera_stream_health)}
            detail={streamable_detail(@camera_stream_health)}
            provenance="Source: live relay (preview stream resolution)"
          />
          <.camera_status_row
            label="Offline"
            value={to_string(@camera_summary.offline)}
            icon="hero-video-camera-slash"
            tone="error"
            provenance="Source: inventory (camera source availability status)"
          />
          <.camera_status_row
            label="Recording"
            value={to_string(@camera_summary.recording)}
            icon="hero-camera"
            tone="info"
            provenance="Source: live relay (active relay sessions)"
          />
          <.camera_status_row
            label="Total Cameras"
            value={to_string(@camera_summary.total)}
            icon="hero-squares-2x2"
            tone="neutral"
            provenance="Source: inventory (camera sources)"
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
                <i class={camera_preview_dot_class(tile)}></i>{tile.label}
              </span>
              <small
                class={camera_preview_detail_class(tile)}
                title={camera_preview_title(tile)}
                data-testid="camera-tile-state"
              >
                {camera_preview_detail(tile)}
              </small>
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
              <small title={camera_inventory_title(tile.status)} data-testid="camera-tile-state">
                {camera_status_label(tile.status)}
              </small>
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
  attr(:detail, :string, default: nil)
  attr(:provenance, :string, default: nil)

  defp camera_status_row(assigns) do
    ~H"""
    <div
      class={["sr-ops-camera-status-row", "tone-#{@tone}"]}
      title={camera_row_title(@provenance, @detail)}
    >
      <span>
        <.icon name={@icon} class="size-4" />
        {@label}
        <small :if={@detail} class="sr-ops-camera-status-detail">{@detail}</small>
      </span>
      <strong>{@value}</strong>
    </div>
    """
  end

  defp camera_row_title(nil, nil), do: nil

  defp camera_row_title(provenance, detail) do
    [provenance, detail]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # Stream operability is derived from the relay preview tiles the panel
  # already resolves (live relay source) — not from inventory availability.
  # Cameras that were never previewed cannot be assumed operable; they are
  # counted as "unchecked".
  defp camera_stream_health(summary, preview_tiles) do
    tiles = List.wrap(preview_tiles)
    streamable = Enum.count(tiles, &(Map.get(&1, :session) != nil))
    blocked = length(tiles) - streamable
    available = Map.get(summary || %{}, :online, 0)

    %{
      streamable: streamable,
      blocked: blocked,
      unchecked: max(available - streamable - blocked, 0),
      contradicted: available > 0 and streamable == 0 and blocked > 0
    }
  end

  defp streamable_tone(%{streamable: 0, blocked: blocked}) when blocked > 0, do: "warning"
  defp streamable_tone(%{streamable: streamable}) when streamable > 0, do: "success"
  defp streamable_tone(_health), do: "neutral"

  defp streamable_detail(%{blocked: 0, unchecked: 0}), do: nil

  defp streamable_detail(%{blocked: blocked, unchecked: unchecked}) do
    [{blocked, "blocked"}, {unchecked, "unchecked"}]
    |> Enum.reject(fn {count, _label} -> count == 0 end)
    |> Enum.map_join(" · ", fn {count, label} -> "#{count} #{label}" end)
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
    case normalize_camera_status(value) do
      status when status in @inventory_available_statuses -> "Available · stream unchecked"
      status when status in @inventory_offline_statuses -> "Offline"
      "empty" -> "No relay"
      "" -> "Unknown"
      status -> String.capitalize(status)
    end
  end

  defp camera_inventory_title(value) do
    case normalize_camera_status(value) do
      status when status in @inventory_available_statuses ->
        "Inventory reports this camera as available; its live stream has not been checked"

      "empty" ->
        nil

      _status ->
        "Source: inventory (camera source availability status)"
    end
  end

  defp camera_preview_detail(%{session: session, detail: detail}) when not is_nil(session), do: detail

  defp camera_preview_detail(tile) do
    reason = camera_preview_block_reason(tile)

    if camera_inventory_available?(tile) do
      "available, not streamable — #{reason}"
    else
      upcase_first(reason)
    end
  end

  defp camera_preview_detail_class(tile) do
    if is_nil(Map.get(tile, :session)) and camera_inventory_available?(tile) do
      "sr-ops-camera-tile-degraded"
    end
  end

  defp camera_preview_dot_class(tile) do
    cond do
      not is_nil(Map.get(tile, :session)) -> "is-online"
      camera_inventory_available?(tile) -> "is-degraded"
      true -> camera_status_dot_class(Map.get(tile, :source_status))
    end
  end

  defp camera_preview_title(%{session: session}) when not is_nil(session), do: "Source: live relay (stream open)"

  defp camera_preview_title(tile) do
    relay_state = Map.get(tile, :error) || "no relay session"

    if camera_inventory_available?(tile) do
      "Inventory reports this camera as available; live relay: #{relay_state}"
    else
      "Source: live relay — #{relay_state}"
    end
  end

  defp camera_preview_block_reason(%{error: error}) when is_binary(error) and error != "" do
    cond do
      String.contains?(error, "Assigned agent") and String.contains?(error, "offline") ->
        "agent offline"

      String.contains?(error, "No relay-capable") ->
        "no relay profile"

      true ->
        error
    end
  end

  defp camera_preview_block_reason(_tile), do: "no relay"

  defp camera_inventory_available?(tile) do
    normalize_camera_status(Map.get(tile, :source_status)) in @inventory_available_statuses
  end

  defp camera_status_dot_class(value) do
    case normalize_camera_status(value) do
      status when status in @inventory_available_statuses -> "is-online"
      status when status in @inventory_offline_statuses -> "is-offline"
      _status -> "is-unknown"
    end
  end

  defp normalize_camera_status(value) do
    value |> to_string() |> String.trim() |> String.downcase()
  end

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upcase_first(other), do: to_string(other)
end
