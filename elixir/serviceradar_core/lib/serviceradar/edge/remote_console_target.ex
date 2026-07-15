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
    controller = controller_map(target)
    endpoint = if map_size(controller) > 0, do: controller, else: device

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
        |> put_present(
          "integration_id",
          string_value(target, [:integration_id, "integration_id"])
        )
        |> put_present(
          "identity_version",
          integer_value(target, [:identity_version, "identity_version"])
        )
        |> put_present(
          "identity_state",
          atom_string(value(target, [:identity_state, "identity_state"]))
        )
        |> put_present("controller_id", string_value(target, [:controller_id, "controller_id"]))
        |> put_present(
          "native_cluster_id",
          string_value(target, [:native_cluster_id, "native_cluster_id"])
        )
        |> put_present("object_kind", string_value(target, [:object_kind, "object_kind"]))
        |> put_present(
          "native_object_id",
          string_value(target, [:native_object_id, "native_object_id"])
        )
        |> put_present(
          "provider_instance_ref",
          string_value(target, [:provider_instance_ref, "provider_instance_ref"])
        )
        |> put_present(
          "inventory_row_id",
          string_value(target, [:inventory_row_id, "inventory_row_id"])
        )
        |> put_present("owner_host_id", string_value(target, [:owner_host_id, "owner_host_id"]))
        |> put_present("cluster", string_value(target, [:cluster, "cluster"]))
        |> put_present("node", string_value(target, [:node, "node"]))
        |> put_present("vmid", integer_value(target, [:vmid, "vmid"]))
        |> put_present("hostname", string_value(endpoint, [:hostname, "hostname", :name, "name"]))
        |> put_present("ip", string_value(endpoint, [:ip, "ip"]))
        |> put_present(
          "controller_device_uid",
          string_value(controller, [:device_uid, "device_uid"])
        )
        |> put_present(
          "controller_ref",
          string_value(controller, [:provider_ref, "provider_ref"])
        )
        |> put_present(
          "controller_integration_id",
          string_value(controller, [:integration_id, "integration_id"])
        )
        |> put_present(
          "controller_provider_instance_ref",
          string_value(controller, [:provider_instance_ref, "provider_instance_ref"])
        )
        |> put_present(
          "controller_virtualization_host_id",
          string_value(controller, [:virtualization_host_id, "virtualization_host_id"])
        )
        |> put_present("controller_origin", string_value(controller, [:base_url, "base_url"]))
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

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value) when is_binary(value), do: value
  defp atom_string(_value), do: nil

  defp controller_map(target) do
    case value(target, [:controller, "controller"]) do
      controller when is_map(controller) -> controller
      _controller -> %{}
    end
  end

  defp integer_value(map, keys) do
    case value(map, keys) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
