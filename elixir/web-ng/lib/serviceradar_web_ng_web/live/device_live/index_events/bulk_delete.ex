defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.BulkDelete do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.IndexCsvImport
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Helpers
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Selection

  require Logger

  def handle_event("bulk_delete_devices", _params, socket) do
    handle_confirm_bulk_delete(socket)
  end

  def handle_event("confirm_bulk_delete", _params, socket) do
    handle_confirm_bulk_delete(socket)
  end

  defp handle_confirm_bulk_delete(socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "devices.bulk_delete") do
      do_bulk_delete(socket, scope)
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk delete devices")}
    end
  end

  defp do_bulk_delete(socket, scope) do
    case bulk_delete_uids(socket) do
      {:ok, uids} ->
        delete_selected_devices(socket, scope, uids)

      {:error, reason} ->
        Logger.error("Bulk device delete failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_bulk_delete_modal, false)
         |> put_flash(:error, reason)}
    end
  end

  defp delete_selected_devices(socket, scope, uids) do
    case Device.bulk_soft_delete(uids, "bulk_delete", scope: scope) do
      :ok ->
        finish_bulk_delete(socket, length(uids))

      {:ok, %{deleted_count: count}} ->
        finish_bulk_delete(socket, count)

      {:error, reason} ->
        Logger.error("Bulk device delete failed for #{inspect(uids)}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_bulk_delete_modal, false)
         |> put_flash(:error, "Bulk delete failed: #{IndexCsvImport.format_device_error(reason)}")}
    end
  end

  defp finish_bulk_delete(socket, count) do
    query = Map.get(socket.assigns.srql || %{}, :query, "")

    {:noreply,
     socket
     |> assign(:show_bulk_delete_modal, false)
     |> assign(:selected_devices, MapSet.new())
     |> assign(:select_all_matching, false)
     |> assign(:total_matching_count, nil)
     |> put_flash(:info, "Deleted #{count} device(s)")
     |> push_patch(to: Helpers.device_list_path(query, socket.assigns.limit))}
  end

  defp bulk_delete_uids(socket) do
    case Selection.validate_device_selection(socket) do
      {:error, _} = error ->
        error

      :ok ->
        socket
        |> Selection.selected_uids()
        |> case do
          [] -> {:error, "No devices selected"}
          uids -> {:ok, uids}
        end
    end
  end
end
