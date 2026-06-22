defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.BulkTags do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Helpers
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Selection

  require Ash.Query

  def handle_event("apply_bulk_tags", %{"bulk" => params}, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.bulk_edit") do
      apply_bulk_tags(params, socket)
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk edit devices")}
    end
  end

  defp apply_bulk_tags(params, socket) do
    scope = socket.assigns.current_scope
    tags_input = Map.get(params, "tags", "")
    tags = parse_bulk_tags(tags_input)

    if tags == %{} do
      {:noreply,
       socket
       |> assign(:bulk_edit_form, to_form(params, as: :bulk))
       |> put_flash(:error, "Enter at least one tag to apply")}
    else
      case apply_tags_to_devices(scope, socket, tags) do
        {:ok, count} ->
          {:noreply,
           socket
           |> assign(:show_bulk_edit_modal, false)
           |> assign(:bulk_edit_form, to_form(%{"tags" => ""}, as: :bulk))
           |> assign(:selected_devices, MapSet.new())
           |> assign(:select_all_matching, false)
           |> assign(:total_matching_count, nil)
           |> put_flash(:info, "Applied tags to #{count} device(s)")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:bulk_edit_form, to_form(params, as: :bulk))
           |> put_flash(:error, "Failed to apply tags: #{reason}")}
      end
    end
  end

  defp apply_tags_to_devices(scope, socket, tags) do
    case Selection.validate_device_selection(socket) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        case Selection.selected_uids(socket) do
          [] -> {:error, "No devices selected"}
          uids -> update_tags_for_uids(scope, uids, tags)
        end
    end
  end

  defp update_tags_for_uids(scope, uids, new_tags) do
    resources = [Device]

    resources
    |> Ash.transaction(fn ->
      case lock_devices_for_bulk_tag(scope, uids) do
        {:ok, devices} ->
          requested_count = length(uids)
          existing_count = length(devices)

          if existing_count < requested_count do
            Ash.DataLayer.rollback(resources, "One or more devices were not found")
          else
            case update_tagged_device_records(devices, new_tags, scope) do
              :ok -> existing_count
              {:error, reason} -> Ash.DataLayer.rollback(resources, reason)
            end
          end

        {:error, error} ->
          Ash.DataLayer.rollback(resources, Helpers.format_changeset_errors(error))
      end
    end)
    |> bulk_tag_transaction_result()
  end

  defp lock_devices_for_bulk_tag(scope, uids) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(uid in ^uids)
      |> Ash.Query.lock(:for_update)

    case Ash.read(query, scope: scope) do
      {:ok, devices} -> {:ok, ash_page_results(devices)}
      {:error, error} -> {:error, error}
    end
  end

  defp bulk_tag_transaction_result({:ok, count}), do: {:ok, count}
  defp bulk_tag_transaction_result({:error, reason}), do: {:error, reason}

  defp update_tagged_device_records(devices, new_tags, scope) do
    Enum.reduce_while(devices, :ok, fn device, :ok ->
      tags =
        device.tags
        |> normalize_device_tags()
        |> Map.merge(new_tags)

      result =
        device
        |> Ash.Changeset.for_update(:update, %{tags: tags}, scope: scope)
        |> Ash.update(scope: scope)

      case result do
        {:ok, _device} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, Helpers.format_changeset_errors(error)}}
      end
    end)
  end

  defp normalize_device_tags(tags) when is_map(tags), do: tags
  defp normalize_device_tags(_tags), do: %{}
  defp ash_page_results(%{results: results}) when is_list(results), do: results
  defp ash_page_results(results) when is_list(results), do: results

  defp parse_bulk_tags(input) when is_binary(input) do
    input
    |> String.split(~r/[\n,]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn entry, acc ->
      case parse_tag_entry(entry) do
        {:ok, key, value} -> Map.put(acc, key, value)
        :skip -> acc
      end
    end)
  end

  defp parse_bulk_tags(_), do: %{}

  defp parse_tag_entry(entry) do
    case String.split(entry, "=", parts: 2) do
      [key, value] -> normalize_tag_entry(key, value)
      [key] -> normalize_tag_entry(key, "")
    end
  end

  defp normalize_tag_entry(key, value) do
    key = String.trim(key)

    if key == "" do
      :skip
    else
      {:ok, key, String.trim(value)}
    end
  end
end
