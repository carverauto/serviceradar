defmodule ServiceRadar.Edge.RemoteConsoleTarget do
  @moduledoc """
  Provider-neutral remote-console target metadata.

  Session resources may still be provider-specific during migration, but brokers
  and browser clients should converge on this shape for target, protocol, and
  transport decisions.
  """

  alias ServiceRadar.Plugins.ValueUtils

  @schema "serviceradar.remote_console_target.v1"
  @default_capabilities ["data", "resize", "close"]

  @type t :: %{
          schema: String.t(),
          provider: String.t() | nil,
          target_ref: String.t(),
          target_type: String.t(),
          protocol: String.t(),
          transport: String.t(),
          device_uid: String.t() | nil,
          agent_id: String.t() | nil,
          capabilities: [String.t()],
          metadata: map()
        }

  @spec proxmox(map(), map(), keyword()) :: t()
  def proxmox(device, target, opts \\ []) when is_map(device) and is_map(target) do
    target_kind = atom_string(value(target, [:target_kind, "target_kind"]))
    console_mode = atom_string(value(target, [:console_mode, "console_mode"]))
    device_uid = string_value(device, [:uid, "uid", :device_uid, "device_uid"])

    %{
      schema: @schema,
      provider: "proxmox",
      target_ref:
        string_value(target, [:provider_ref, "provider_ref", :target_ref, "target_ref"]) ||
          provider_ref("proxmox", device_uid),
      target_type: proxmox_target_type(target_kind),
      protocol: proxmox_protocol(console_mode),
      transport: proxmox_transport(console_mode),
      device_uid: device_uid,
      agent_id: string_value(target, [:agent_id, "agent_id"]) || Keyword.get(opts, :agent_id),
      capabilities: Keyword.get(opts, :capabilities, @default_capabilities),
      metadata:
        %{}
        |> put_present("target_kind", target_kind)
        |> put_present("console_mode", console_mode)
        |> put_present("hostname", string_value(device, [:hostname, "hostname", :name, "name"]))
        |> put_present("ip", string_value(device, [:ip, "ip"]))
    }
  end

  @spec build(map(), keyword()) :: t()
  def build(attrs, opts \\ []) when is_map(attrs) do
    device_uid = string_value(attrs, [:device_uid, "device_uid", :uid, "uid"])
    provider = string_value(attrs, [:provider, "provider"]) || "generic"

    target_ref =
      string_value(attrs, [:target_ref, "target_ref"]) || provider_ref(provider, device_uid)

    protocol = string_value(attrs, [:protocol, "protocol"]) || "ssh"
    transport = string_value(attrs, [:transport, "transport"]) || default_transport(protocol)

    %{
      schema: @schema,
      provider: provider,
      target_ref: target_ref,
      target_type: string_value(attrs, [:target_type, "target_type"]) || "device",
      protocol: protocol,
      transport: transport,
      device_uid: device_uid,
      agent_id: string_value(attrs, [:agent_id, "agent_id"]) || Keyword.get(opts, :agent_id),
      capabilities: list_value(attrs, [:capabilities, "capabilities"]) || @default_capabilities,
      metadata: map_value(attrs, [:metadata, "metadata"]) || %{}
    }
  end

  @spec to_metadata(t()) :: map()
  def to_metadata(target) when is_map(target) do
    target
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} or value == [] end)
    |> Map.new()
  end

  def schema, do: @schema

  defp provider_ref(_provider, nil), do: nil
  defp provider_ref(provider, device_uid), do: "#{provider}:device:#{device_uid}"

  defp proxmox_target_type("pve_host"), do: "host"
  defp proxmox_target_type("qemu_guest"), do: "guest"
  defp proxmox_target_type("lxc_guest"), do: "guest"
  defp proxmox_target_type(_target_kind), do: "device"

  defp proxmox_protocol("ssh"), do: "ssh"
  defp proxmox_protocol("proxmox_termproxy"), do: "proxmox-termproxy"
  defp proxmox_protocol("proxmox_vncwebsocket"), do: "vnc"
  defp proxmox_protocol(_console_mode), do: "console"

  defp proxmox_transport("ssh"), do: "pty"
  defp proxmox_transport("proxmox_termproxy"), do: "pty"
  defp proxmox_transport("proxmox_vncwebsocket"), do: "framebuffer"
  defp proxmox_transport(_console_mode), do: "stream"

  defp default_transport("ssh"), do: "pty"
  defp default_transport("rdp"), do: "framebuffer"
  defp default_transport("vnc"), do: "framebuffer"
  defp default_transport(_protocol), do: "stream"

  defp value(map, keys), do: ValueUtils.raw_value(map, keys)

  defp map_value(map, keys), do: ValueUtils.map_value(map, keys, stringify_keys: true)

  defp list_value(map, keys) do
    map
    |> ValueUtils.list_value(keys)
    |> case do
      values when is_list(values) ->
        values
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        nil
    end
  end

  defp string_value(map, keys) do
    case ValueUtils.string_value(map, keys) do
      "" -> nil
      value -> value
    end
  end

  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value) when is_binary(value), do: value
  defp atom_string(_value), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
