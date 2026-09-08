defmodule ServiceRadarWebNGWeb.DeviceLive.SourceObservationData do
  @moduledoc false

  alias ServiceRadar.Inventory.DeviceSourceObservation
  alias ServiceRadar.Plugins.IntegrationCatalog

  require Logger

  def load(scope, device_uid) when is_binary(device_uid) and device_uid != "" do
    case DeviceSourceObservation.list_by_device(device_uid, actor: scope_actor(scope)) do
      {:ok, observations} when is_list(observations) ->
        descriptors = inventory_source_descriptors()
        Enum.map(observations, &serialize(&1, descriptors))

      {:error, _reason} ->
        Logger.warning("Failed to load device source observations")
        []
    end
  end

  def load(_scope, _device_uid), do: []

  defp serialize(observation, descriptors) do
    descriptor = Map.get(descriptors, observation.source, %{})

    %{
      "source" => observation.source,
      "source_label" => descriptor["label"],
      "source_instance" => observation.source_instance,
      "source_object_id" => observation.source_object_id,
      "collection_id" => observation.collection_id,
      "present" => observation.present,
      "last_observed_at" => iso8601(observation.last_observed_at),
      "absent_since" => iso8601(observation.absent_since),
      "partition" => observation.site_name,
      "management_status" => observation.management_status,
      "metadata" => observation.metadata || %{},
      "metadata_fields" => descriptor["metadata_fields"] || []
    }
  end

  defp inventory_source_descriptors do
    case IntegrationCatalog.load() do
      {:ok, catalog} -> Map.new(catalog.inventory_sources, &{&1["source"], &1})
      {:error, _reason} -> %{}
    end
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp scope_actor(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil
end
