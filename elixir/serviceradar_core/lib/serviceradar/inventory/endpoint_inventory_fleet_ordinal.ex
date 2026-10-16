defmodule ServiceRadar.Inventory.EndpointInventoryFleetOrdinal do
  @moduledoc """
  Endpoint-inventory compatibility API for the shared fleet identity dictionary.

  Service-component IDs retain the endpoint API's exclusion. All canonical
  inventory devices use FleetIdentity, independently of endpoint ingestion.
  """

  alias ServiceRadar.Inventory.FleetIdentity

  @spec ensure_allocated(String.t() | nil, keyword()) :: {:ok, integer() | nil} | {:error, term()}
  def ensure_allocated(device_uid, opts \\ [])
  def ensure_allocated(nil, _opts), do: {:ok, nil}

  def ensure_allocated(device_uid, opts) when is_binary(device_uid) do
    case String.trim(device_uid) do
      "" -> {:ok, nil}
      "serviceradar:" <> _ -> {:ok, nil}
      uid -> FleetIdentity.ensure_device(uid, opts)
    end
  end

  @spec ordinal_for(String.t(), keyword()) :: integer() | nil
  def ordinal_for(device_uid, opts \\ [])
  def ordinal_for("serviceradar:" <> _, _opts), do: nil

  def ordinal_for(device_uid, opts) when is_binary(device_uid),
    do: FleetIdentity.device_ordinal(device_uid, opts)
end
