defmodule ServiceRadar.Inventory.DeviceClaimPolicy do
  @moduledoc """
  Guards inventory ingestors from reusing canonical device UIDs across asset
  ownership boundaries.

  Plugin descriptors often represent child assets managed by an agent or
  controller. Those descriptors may carry a producer-supplied `device_uid`, but
  that UID is only safe to reuse when the existing device is compatible with the
  asset being ingested. Otherwise the ingestor must create or resolve a separate
  canonical device and link the child asset to that device.
  """

  alias ServiceRadar.Inventory.Device

  @spec reusable_for_claim?(String.t() | nil, atom(), term()) :: boolean()
  def reusable_for_claim?(uid, claim_type, actor)

  def reusable_for_claim?(uid, _claim_type, _actor) when uid in [nil, ""], do: true

  def reusable_for_claim?(uid, claim_type, actor) when is_binary(uid) do
    case Device.get_by_uid(uid, false, actor: actor) do
      {:ok, %Device{} = device} ->
        reusable_device?(device, claim_type)

      {:ok, nil} ->
        true

      {:error, reason} ->
        ash_not_found?(reason)
    end
  rescue
    _ -> false
  end

  def reusable_for_claim?(_uid, _claim_type, _actor), do: true

  defp reusable_device?(%Device{} = device, :camera) do
    camera_device?(device) and not agent_managed_device?(device)
  end

  defp reusable_device?(%Device{} = device, :managed_child_asset) do
    not agent_managed_device?(device)
  end

  defp reusable_device?(%Device{}, _claim_type), do: true

  defp camera_device?(%Device{type_id: 7}), do: true

  defp camera_device?(%Device{type: type}) when is_binary(type) do
    String.downcase(String.trim(type)) == "camera"
  end

  defp camera_device?(_device), do: false

  defp agent_managed_device?(%Device{agent_id: agent_id})
       when is_binary(agent_id) and agent_id != "", do: true

  defp agent_managed_device?(%Device{discovery_sources: sources}) when is_list(sources) do
    Enum.any?(sources, &(&1 in ["agent", "sysmon", "system_monitor"]))
  end

  defp agent_managed_device?(_device), do: false

  defp ash_not_found?(%Ash.Error.Query.NotFound{}), do: true

  defp ash_not_found?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &ash_not_found?/1)
  end

  defp ash_not_found?(_reason), do: false
end
