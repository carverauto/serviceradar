defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Navigation do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Helpers
  alias ServiceRadarWebNGWeb.DeviceLive.IndexPath
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Breakdown
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/devices")}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: "/devices")}
  end

  def handle_event("srql_paginate", params, socket) do
    query = Map.get(socket.assigns.srql || %{}, :query, "")

    path =
      IndexPath.list_path(
        query: query,
        page: Map.get(params, "page"),
        cursor: Map.get(params, "cursor")
      )

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "devices")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/devices")}
  end

  def handle_event("toggle_include_deleted", _params, socket) do
    query = Map.get(socket.assigns.srql || %{}, :query, "") || ""
    updated_query = Helpers.toggle_include_deleted_query(query)
    path = Helpers.device_list_path(updated_query, socket.assigns.limit)
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("open_breakdown_modal", %{"kind" => kind}, socket) do
    stats = Map.get(socket.assigns, :device_stats, %{})

    modal =
      case kind do
        "type" ->
          Breakdown.breakdown_modal_data("Device Types", "type", Map.get(stats, :by_type, []))

        "vendor" ->
          Breakdown.breakdown_modal_data("Device Vendors", "vendor_name", Map.get(stats, :by_vendor, []))

        _ ->
          nil
      end

    {:noreply, assign(socket, breakdown_modal: modal, breakdown_search: "")}
  end

  def handle_event("close_breakdown_modal", _params, socket) do
    {:noreply, assign(socket, breakdown_modal: nil, breakdown_search: "")}
  end

  def handle_event("breakdown_search", %{"q" => query}, socket) do
    {:noreply, assign(socket, :breakdown_search, to_string(query || ""))}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    socket =
      socket
      |> SRQLPage.handle_event("srql_builder_add_filter", params, entity: "devices")
      |> assign(:selected_devices, MapSet.new())
      |> assign(:select_all_matching, false)
      |> assign(:total_matching_count, nil)

    {:noreply, socket}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    socket =
      socket
      |> SRQLPage.handle_event("srql_builder_remove_filter", params, entity: "devices")
      |> assign(:selected_devices, MapSet.new())
      |> assign(:select_all_matching, false)
      |> assign(:total_matching_count, nil)

    {:noreply, socket}
  end
end
