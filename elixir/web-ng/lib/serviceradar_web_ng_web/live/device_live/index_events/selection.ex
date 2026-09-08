defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Selection do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData

  def handle_event("toggle_device_select", %{"uid" => uid}, socket) do
    selected = socket.assigns.selected_devices

    updated =
      if MapSet.member?(selected, uid) do
        MapSet.delete(selected, uid)
      else
        MapSet.put(selected, uid)
      end

    {:noreply,
     socket
     |> assign(:selected_devices, updated)
     |> assign(:select_all_matching, false)
     |> assign(:total_matching_count, nil)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    devices = socket.assigns.devices
    selected = socket.assigns.selected_devices

    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    updated =
      if MapSet.subset?(device_uids, selected) do
        MapSet.difference(selected, device_uids)
      else
        MapSet.union(selected, device_uids)
      end

    {:noreply,
     socket
     |> assign(:selected_devices, updated)
     |> assign(:select_all_matching, false)
     |> assign(:total_matching_count, nil)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_devices, MapSet.new())}
  end

  def handle_event("launch_ansible_for_selection", _params, socket) do
    cond do
      not RBAC.can?(socket.assigns.current_scope, "ansible.runs.launch") ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You are not authorized to launch Ansible playbooks."
         )}

      socket.assigns.select_all_matching ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Choose specific devices before launching an Ansible playbook."
         )}

      true ->
        case validate_device_selection(socket) do
          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}

          :ok ->
            device_uids = socket |> selected_uids() |> Enum.sort() |> Enum.join(",")

            {:noreply,
             push_navigate(
               socket,
               to: ~p"/ansible/launch?#{%{devices: device_uids}}"
             )}
        end
    end
  end

  def handle_event("open_bulk_edit_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.bulk_edit") do
      {:noreply, assign(socket, :show_bulk_edit_modal, true)}
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk edit devices")}
    end
  end

  def handle_event("open_bulk_delete_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.bulk_delete") do
      {:noreply, assign(socket, :show_bulk_delete_modal, true)}
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk delete devices")}
    end
  end

  def handle_event("open_bulk_availability_source_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.bulk_edit") do
      {:noreply, assign(socket, :show_bulk_availability_source_modal, true)}
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk edit devices")}
    end
  end

  def handle_event("close_bulk_edit_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_bulk_edit_modal, false)
     |> assign(:bulk_edit_form, to_form(%{"tags" => ""}, as: :bulk))}
  end

  def handle_event("close_bulk_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_bulk_delete_modal, false)}
  end

  def handle_event("close_bulk_availability_source_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_bulk_availability_source_modal, false)
     |> assign(:availability_source_form, to_form(%{"agent_id" => ""}, as: :availability_source))}
  end

  def handle_event("toggle_select_all_matching", _params, socket) do
    current = socket.assigns.select_all_matching

    socket =
      if current do
        socket
        |> assign(:select_all_matching, false)
        |> assign(:selected_devices, MapSet.new())
        |> assign(:total_matching_count, nil)
      else
        scope = socket.assigns.current_scope
        query = Map.get(socket.assigns.srql || %{}, :query, "")
        total = IndexData.get_total_matching_count(scope, query)

        socket
        |> assign(:select_all_matching, true)
        |> assign(:total_matching_count, total)
      end

    {:noreply, socket}
  end

  def selected_uids(socket) do
    if socket.assigns.select_all_matching do
      scope = socket.assigns.current_scope
      query = Map.get(socket.assigns.srql || %{}, :query, "")
      IndexData.get_all_matching_uids(scope, query)
    else
      socket.assigns.selected_devices
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
    end
  end

  def validate_device_selection(socket) do
    cond do
      not socket.assigns.select_all_matching and
          MapSet.size(socket.assigns.selected_devices) == 0 ->
        {:error, "Select at least one device first."}

      socket.assigns.select_all_matching and
          not is_integer(socket.assigns.total_matching_count) ->
        {:error, "Unable to determine selection size. Please try again."}

      socket.assigns.select_all_matching and socket.assigns.total_matching_count > 10_000 ->
        {:error, "Too many devices selected. Narrow your filters and try again."}

      true ->
        :ok
    end
  end
end
