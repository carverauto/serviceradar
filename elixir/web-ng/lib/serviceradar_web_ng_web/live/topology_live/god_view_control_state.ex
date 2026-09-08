defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewControlState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias ServiceRadarWebNGWeb.TopologyLive.GodViewMtrOverlay

  def toggle_causal_filter(socket, state) do
    key =
      case state do
        "root_cause" -> :root_cause
        "affected" -> :affected
        "healthy" -> :healthy
        _ -> :unknown
      end

    filters = Map.update!(socket.assigns.causal_filters, key, &(!&1))

    socket
    |> assign(:causal_filters, filters)
    |> push_event("god_view:set_filters", %{filters: stringify_filter_keys(filters)})
  end

  def reset_view(socket) do
    push_event(socket, "god_view:reset_view", %{})
  end

  def set_zoom_mode(socket, mode) do
    requested_mode = normalize_zoom_mode(mode)
    current_mode = socket.assigns.zoom_mode || "local"

    mode =
      if requested_mode == "auto" and current_mode == "auto" do
        "local"
      else
        requested_mode
      end

    socket
    |> assign(:zoom_mode, mode)
    |> push_event("god_view:set_zoom_mode", %{mode: mode})
  end

  def toggle_visual_layer(socket, layer) do
    key =
      case layer do
        "mantle" -> :mantle
        "crust" -> :crust
        "atmosphere" -> :atmosphere
        _ -> :security
      end

    layers = Map.update!(socket.assigns.visual_layers, key, &(!&1))

    socket
    |> assign(:visual_layers, layers)
    |> push_event("god_view:set_layers", %{layers: stringify_filter_keys(layers)})
  end

  def toggle_topology_layer(socket, layer) do
    key =
      case layer do
        "backbone" -> :backbone
        "inferred" -> :inferred
        "mtr_paths" -> :mtr_paths
        _ -> :endpoints
      end

    layers = Map.update!(socket.assigns.topology_layers, key, &(!&1))

    socket =
      socket
      |> assign(:topology_layers, layers)
      |> push_event("god_view:set_topology_layers", %{layers: stringify_filter_keys(layers)})

    if key == :mtr_paths do
      if layers.mtr_paths,
        do: GodViewMtrOverlay.push_path_data(socket),
        else: GodViewMtrOverlay.clear_path_data(socket)
    else
      socket
    end
  end

  @doc """
  Enables the attachment/inferred topology layers as the explicit
  call-to-action of the backbone-empty warning. Reuses the same
  `god_view:set_topology_layers` event path as the layer toggles so
  client layer state stays in sync with the LiveView assigns.
  """
  def enable_attachment_layers(socket) do
    layers =
      socket.assigns.topology_layers
      |> Map.put(:inferred, true)
      |> Map.put(:endpoints, true)

    socket
    |> assign(:topology_layers, layers)
    |> push_event("god_view:set_topology_layers", %{layers: stringify_filter_keys(layers)})
  end

  def toggle_controls_panel(socket) do
    update(socket, :controls_collapsed, &(!&1))
  end

  def set_controls_panel(socket, collapsed) do
    assign(socket, :controls_collapsed, truthy?(collapsed))
  end

  defp stringify_filter_keys(filters) do
    Map.new(filters, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp normalize_zoom_mode("global"), do: "global"
  defp normalize_zoom_mode("regional"), do: "regional"
  defp normalize_zoom_mode("local"), do: "local"
  defp normalize_zoom_mode(_), do: "auto"

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when value in ["true", "1", 1, true], do: true
  defp truthy?(_), do: false
end
