defmodule ServiceRadar.Inventory.DeviceLifecycle do
  @moduledoc """
  Helpers for device in-service lifecycle decisions.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device

  @device_uid_keys [
    :device_uid,
    "device_uid",
    :target_device_uid,
    "target_device_uid",
    :source_device_uid,
    "source_device_uid",
    :camera_device_uid,
    "camera_device_uid",
    :uid,
    "uid",
    :id,
    "id"
  ]
  @device_container_keys [:device, "device"]
  @endpoint_container_keys [:src_endpoint, "src_endpoint", :dst_endpoint, "dst_endpoint"]
  @metadata_container_keys [:metadata, "metadata"]

  @spec active?(String.t() | nil, keyword()) :: boolean()
  def active?(device_uid, opts \\ [])
  def active?(nil, _opts), do: true
  def active?("", _opts), do: true

  def active?(device_uid, opts) when is_binary(device_uid) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:device_lifecycle))

    case Device.get_by_uid(device_uid, true, actor: actor) do
      {:ok, %Device{is_active: false}} -> false
      {:ok, _device} -> true
      {:error, _reason} -> true
    end
  rescue
    _ -> true
  end

  @spec suppress_operational_event?(map(), keyword()) :: boolean()
  def suppress_operational_event?(attrs, opts \\ []) when is_map(attrs) do
    attrs
    |> device_uid()
    |> active?(opts)
    |> Kernel.not()
  end

  @spec device_uid(map()) :: String.t() | nil
  def device_uid(attrs) when is_map(attrs) do
    first_present([
      first_key_value(attrs, @device_uid_keys),
      nested_first_key_value(attrs, @device_container_keys, @device_uid_keys),
      nested_first_key_value(attrs, @endpoint_container_keys, @device_uid_keys),
      nested_first_key_value(attrs, @metadata_container_keys, @device_uid_keys)
    ])
  end

  def device_uid(_attrs), do: nil

  defp nested_first_key_value(map, container_keys, value_keys) do
    Enum.find_value(container_keys, fn key ->
      case Map.get(map, key) do
        nested when is_map(nested) -> first_key_value(nested, value_keys)
        _ -> nil
      end
    end)
  end

  defp first_key_value(map, keys) do
    Enum.find_value(keys, fn key -> present_string(Map.get(map, key)) end)
  end

  defp first_present(values), do: Enum.find_value(values, &present_string/1)

  defp present_string(nil), do: nil

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> present_string()

  defp present_string(_value), do: nil
end
