defmodule ServiceRadar.Edge.RemoteAccessDialTarget do
  @moduledoc """
  Chooses the address an inventory-device remote-access session connects to.

  Device-reported labels need not resolve from the selected agent, so address
  selection must not prefer them over an inventory IP. Override authorization
  belongs to the caller; this module only selects the dial target.

  See `docs/docs/remote-access.md#connection-address` for the operator contract.
  """

  alias ServiceRadar.Plugins.ValueUtils

  @address_keys [:ip, "ip"]
  @name_keys [:hostname, "hostname", :name, "name"]
  @uid_keys [:uid, "uid"]

  @doc """
  Returns the host to dial for `device`, honouring an operator `override`.
  """
  @spec resolve(map(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :missing_remote_access_target}
  def resolve(device, override) when is_map(device) do
    case present(override) || string_value(device, @address_keys) ||
           string_value(device, @name_keys) || string_value(device, @uid_keys) do
      nil -> {:error, :missing_remote_access_target}
      host -> {:ok, host}
    end
  end

  defp string_value(device, keys) do
    device
    |> ValueUtils.string_value(keys)
    |> present()
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
