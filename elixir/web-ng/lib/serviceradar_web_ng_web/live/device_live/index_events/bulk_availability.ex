defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.BulkAvailability do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Helpers
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Selection

  require Ash.Query

  def handle_event("apply_bulk_availability_source", %{"availability_source" => params}, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.bulk_edit") do
      apply_bulk_availability_source(params, socket)
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk edit devices")}
    end
  end

  defp apply_bulk_availability_source(params, socket) do
    scope = socket.assigns.current_scope
    agent_id = params |> Map.get("agent_id", "") |> blank_to_nil()

    case apply_availability_source_to_devices(scope, socket, agent_id) do
      {:ok, count} ->
        label = if is_binary(agent_id), do: "Set availability source", else: "Cleared availability source"
        query = Map.get(socket.assigns.srql || %{}, :query, "")

        {:noreply,
         socket
         |> assign(:show_bulk_availability_source_modal, false)
         |> assign(:availability_source_form, to_form(%{"agent_id" => ""}, as: :availability_source))
         |> assign(:selected_devices, MapSet.new())
         |> assign(:select_all_matching, false)
         |> assign(:total_matching_count, nil)
         |> put_flash(:info, "#{label} for #{count} device(s)")
         |> push_patch(to: Helpers.device_list_path(query, socket.assigns.limit))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:availability_source_form, to_form(params, as: :availability_source))
         |> put_flash(:error, "Failed to set availability source: #{reason}")}
    end
  end

  defp apply_availability_source_to_devices(scope, socket, agent_id) do
    case Selection.validate_device_selection(socket) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        case Selection.selected_uids(socket) do
          [] -> {:error, "No devices selected"}
          uids -> update_availability_source_for_uids(scope, uids, agent_id)
        end
    end
  end

  defp update_availability_source_for_uids(scope, uids, agent_id) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(uid in ^uids)

    case Ash.count(query, scope: scope) do
      {:ok, existing_count} ->
        requested_count = length(uids)

        result =
          Ash.bulk_update(
            query,
            :set_availability_source,
            %{
              availability_source_agent_id: agent_id,
              availability_source_profile_id: nil
            },
            scope: scope,
            return_records?: false,
            return_errors?: true
          )

        Helpers.handle_bulk_update_result(result, existing_count, requested_count)

      {:error, error} ->
        {:error, Helpers.format_changeset_errors(error)}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
