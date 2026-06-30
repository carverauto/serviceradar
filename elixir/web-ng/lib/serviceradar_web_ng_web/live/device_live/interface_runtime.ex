defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData
  alias ServiceRadarWebNGWeb.DeviceLive.NorthboundInterfaceRuntime

  def toggle_select(socket, uid) do
    selected = socket.assigns.selected_interfaces

    updated =
      if MapSet.member?(selected, uid) do
        MapSet.delete(selected, uid)
      else
        MapSet.put(selected, uid)
      end

    assign(socket, :selected_interfaces, updated)
  end

  def toggle_select_all(socket) do
    interfaces = socket.assigns.network_interfaces
    selected = socket.assigns.selected_interfaces

    all_uids =
      interfaces |> Enum.map(&Map.get(&1, "interface_uid")) |> Enum.filter(& &1) |> MapSet.new()

    updated =
      if MapSet.size(selected) == MapSet.size(all_uids) and MapSet.equal?(selected, all_uids) do
        MapSet.new()
      else
        all_uids
      end

    assign(socket, :selected_interfaces, updated)
  end

  def clear_selection(socket) do
    assign(socket, :selected_interfaces, MapSet.new())
  end

  def run_task_for_selection(socket) do
    cond do
      not NorthboundInterfaceRuntime.can_launch?(socket.assigns.current_scope) ->
        put_flash(socket, :error, NorthboundInterfaceRuntime.launch_permission_error())

      MapSet.size(socket.assigns.selected_interfaces) == 0 ->
        put_flash(socket, :error, "Select at least one interface before Run Task.")

      socket.assigns.northbound_interface_actions == [] ->
        put_flash(socket, :error, "No launchable interface task integrations are configured.")

      true ->
        action = List.first(socket.assigns.northbound_interface_actions)
        NorthboundInterfaceRuntime.open_modal(socket, action)
    end
  end

  def open_bulk_edit(socket) do
    assign(socket, :show_interfaces_bulk_edit, true)
  end

  def close_bulk_edit(socket) do
    socket
    |> assign(:show_interfaces_bulk_edit, false)
    |> assign(:interfaces_bulk_edit_form, to_form(%{"action" => "favorite"}, as: :bulk))
  end

  def apply_bulk_edit(socket, params) do
    selected = socket.assigns.selected_interfaces
    device_uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    action = Map.get(params, "action", "favorite")

    {socket, success_count, action_label} =
      case action do
        "favorite" ->
          {count, new_favorites} =
            InterfaceData.bulk_update_favorites(
              scope,
              device_uid,
              selected,
              true,
              socket.assigns.favorited_interfaces
            )

          {assign(socket, :favorited_interfaces, new_favorites), count, "added to favorites"}

        "unfavorite" ->
          {count, new_favorites} =
            InterfaceData.bulk_update_favorites(
              scope,
              device_uid,
              selected,
              false,
              socket.assigns.favorited_interfaces
            )

          {assign(socket, :favorited_interfaces, new_favorites), count, "removed from favorites"}

        "enable_metrics" ->
          count = InterfaceData.bulk_update_metrics(scope, device_uid, selected, true)
          {socket, count, "enabled for metrics collection"}

        "disable_metrics" ->
          count = InterfaceData.bulk_update_metrics(scope, device_uid, selected, false)
          {socket, count, "disabled for metrics collection"}

        "add_tags" ->
          tags_string = Map.get(params, "tags", "")
          tags = InterfaceData.parse_tags(tags_string)

          if tags == [] do
            {socket, 0, "tagged (no tags provided)"}
          else
            count = InterfaceData.bulk_update_tags(scope, device_uid, selected, tags)
            {socket, count, "tagged with: #{Enum.join(tags, ", ")}"}
          end

        _ ->
          {socket, 0, "updated"}
      end

    socket
    |> assign(:show_interfaces_bulk_edit, false)
    |> assign(:selected_interfaces, MapSet.new())
    |> assign(:interfaces_bulk_edit_form, to_form(%{"action" => "favorite"}, as: :bulk))
    |> put_flash(:info, "#{success_count} interface(s) #{action_label}")
  end

  def toggle_favorite(socket, uid) do
    favorited = socket.assigns.favorited_interfaces
    device_uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    new_favorite_state = not MapSet.member?(favorited, uid)

    case InterfaceData.upsert_interface_setting(scope, device_uid, uid, %{favorited: new_favorite_state}) do
      {:ok, _setting} ->
        updated =
          if new_favorite_state do
            MapSet.put(favorited, uid)
          else
            MapSet.delete(favorited, uid)
          end

        assign(socket, :favorited_interfaces, updated)

      {:error, _reason} ->
        put_flash(socket, :error, "Failed to update favorite status")
    end
  end
end
