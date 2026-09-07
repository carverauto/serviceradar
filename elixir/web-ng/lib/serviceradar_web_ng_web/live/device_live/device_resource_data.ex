defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceResourceData do
  @moduledoc false

  alias Ash.Error.Invalid
  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceFormData

  require Ash.Query

  def load(scope, device_uid, include_deleted \\ true) do
    case Device.get_by_uid(device_uid, include_deleted, scope: scope) do
      {:ok, nil} -> {:error, :not_found}
      other -> other
    end
  end

  def soft_delete(scope, device_uid, deleted_by) do
    with {:ok, device} <- load(scope, device_uid) do
      Device.soft_delete(device, "ui_delete", deleted_by, scope: scope)
    end
  end

  def update(scope, device_uid, params) do
    attrs =
      %{
        hostname: params["hostname"],
        ip: params["ip"],
        vendor_name: params["vendor_name"],
        model: params["model"],
        is_managed: DeviceFormData.parse_bool(params["is_managed"]),
        is_trusted: DeviceFormData.parse_bool(params["is_trusted"]),
        tags: DeviceFormData.parse_tags(params["tags"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    with {:ok, device} <- load(scope, device_uid, false) do
      device
      |> Ash.Changeset.for_update(:update, attrs)
      |> Ash.update(scope: scope)
    end
  end

  def restore(scope, device_uid) do
    with {:ok, device} <- load(scope, device_uid),
         {:ok, _} <- Device.restore(device, scope: scope) do
      :ok
    else
      {:error, %Invalid{} = error} ->
        if stale_record_error?(error) do
          case force_restore(scope, device_uid) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def set_active(scope, device_uid, active?) do
    with {:ok, device} <- load(scope, device_uid) do
      set_active_state(device, active?, scope)
    end
  end

  defp stale_record_error?(%Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_record_error?(_), do: false

  defp force_restore(scope, device_uid) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid == ^device_uid)

    case Ash.bulk_update(query, :restore, %{},
           scope: scope,
           return_errors?: true,
           return_records?: false
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        {:error, List.first(errors) || :partial_failure}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, List.first(errors) || :bulk_update_failed}
    end
  end

  defp set_active_state(device, true, scope), do: Device.mark_active(device, scope: scope)
  defp set_active_state(device, false, scope), do: Device.mark_inactive(device, scope: scope)
end
