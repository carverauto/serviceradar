defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntime
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

  def run_action_for_selection(socket) do
    cond do
      not NorthboundInterfaceRuntime.can_launch?(socket.assigns.current_scope) ->
        put_flash(socket, :error, NorthboundInterfaceRuntime.launch_permission_error())

      MapSet.size(socket.assigns.selected_interfaces) == 0 ->
        put_flash(socket, :error, "Select at least one interface before running an action.")

      socket.assigns.northbound_interface_actions == [] ->
        put_flash(socket, :error, "No launchable interface action integrations are configured.")

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

  def apply_bulk_edit(socket, params, srql_module) do
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
    |> reload_settings_and_metrics(srql_module)
    |> put_flash(:info, "#{success_count} interface(s) #{action_label}")
  end

  def toggle_favorite(socket, uid, srql_module) do
    favorited = socket.assigns.favorited_interfaces
    device_uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    new_favorite_state = not MapSet.member?(favorited, uid)

    case InterfaceData.upsert_interface_setting(scope, device_uid, uid, %{favorited: new_favorite_state}) do
      {:ok, _setting} ->
        reload_settings_and_metrics(socket, srql_module)

      {:error, _reason} ->
        put_flash(socket, :error, "Failed to update favorite status")
    end
  end

  def toggle_metrics(socket, uid, srql_module) do
    enabled = socket.assigns.metrics_enabled_interfaces
    device_uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    enable? = not MapSet.member?(enabled, uid)
    attrs = InterfaceData.metrics_update_attrs(scope, device_uid, uid, enable?)

    case InterfaceData.upsert_interface_setting(scope, device_uid, uid, attrs) do
      {:ok, _setting} ->
        socket
        |> reload_settings_and_metrics(srql_module)
        |> put_flash(
          :info,
          if(enable?,
            do: "SNMP collection enabled for this interface",
            else: "SNMP collection disabled for this interface"
          )
        )

      {:error, _reason} ->
        put_flash(socket, :error, "Failed to update metrics collection")
    end
  end

  def enable_favorited_metrics(socket, srql_module) do
    favorited = socket.assigns.favorited_interfaces

    if MapSet.size(favorited) == 0 do
      put_flash(socket, :error, "Star at least one interface first.")
    else
      count =
        InterfaceData.bulk_update_metrics(
          socket.assigns.current_scope,
          socket.assigns.device_uid,
          favorited,
          true
        )

      socket
      |> reload_settings_and_metrics(srql_module)
      |> put_flash(:info, "#{count} favorited interface(s) enabled for SNMP collection")
    end
  end

  defp reload_settings_and_metrics(socket, srql_module) do
    settings =
      InterfaceData.load_interface_settings(
        socket.assigns.current_scope,
        socket.assigns.device_uid
      )

    socket
    |> assign(:favorited_interfaces, settings.favorited)
    |> assign(:metrics_enabled_interfaces, settings.metrics_enabled)
    |> assign(
      :network_interfaces,
      InterfaceData.apply_interface_settings(socket.assigns.network_interfaces, settings.by_uid)
    )
    |> DeviceTabRuntime.begin_interface_metrics_refresh(socket.assigns.device_uid, srql_module)
  end
end
