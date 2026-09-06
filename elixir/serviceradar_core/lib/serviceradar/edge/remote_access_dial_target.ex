defmodule ServiceRadar.Edge.RemoteAccessDialTarget do
  @moduledoc """
  Chooses the address an inventory-device remote-access session connects to.

  The device address recorded in inventory is the address ServiceRadar's own
  collectors already reached the device on, so it is the one an agent can dial.
  A device hostname is a label the device reports about itself -- an SNMP
  `sysName`, a Proxmox node name -- and nothing makes it resolvable from the
  agent that opens the session. Selecting the label first is what sent SSH
  sessions to `dial tcp: lookup <name>: server misbehaving` while the routable
  address sat unused on the same device row.

  The hostname stays as the fallback for a device inventory knows only by name,
  and an operator-supplied host still wins outright: that is the override for a
  device whose inventory address is not the one to connect through.

  Both addresses reach the session either way -- `target` metadata carries
  `hostname` and `ip` -- so this choice decides only what is dialed.
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
