defmodule ServiceRadar.Inventory.DeviceIdentifierNotifier do
  @moduledoc """
  Invalidates IP identity-cache entries when device identifiers change.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier

  @impl Ash.Notifier
  def notify(%Notification{
        resource: DeviceIdentifier,
        action: %{type: action_type},
        data: record,
        changeset: changeset
      })
      when action_type in [:create, :update, :destroy] do
    invalidate_identity_cache(changeset_data(changeset))
    invalidate_identity_cache(record)
    :ok
  end

  def notify(_notification), do: :ok

  defp changeset_data(%{data: data}), do: data
  defp changeset_data(_), do: nil

  defp invalidate_identity_cache(%{
         identifier_type: type,
         identifier_value: value,
         device_id: device_id
       }) do
    invalidate_identifier_ip(type, value)
    invalidate_device_ip(device_id)
  end

  defp invalidate_identity_cache(_record), do: :ok

  defp invalidate_identifier_ip(type, value)
       when type in [:ip, "ip"] and is_binary(value) and value != "" do
    IdentityCache.delete(value)
  end

  defp invalidate_identifier_ip(_type, _value), do: :ok

  defp invalidate_device_ip(device_id) when is_binary(device_id) and device_id != "" do
    case Device.get_by_uid(device_id, true, actor: SystemActor.system(:identity_cache)) do
      {:ok, %Device{ip: ip}} when is_binary(ip) and ip != "" ->
        IdentityCache.delete(ip)

      _ ->
        :ok
    end
  end

  defp invalidate_device_ip(_device_id), do: :ok
end
