defmodule ServiceRadar.Edge.RemoteConsoleTargetResolver do
  @moduledoc """
  Resolves provider-specific inventory rows into remote-console target metadata.

  A Proxmox guest is a console subject, not a network controller. Guest console
  traffic is therefore always bound to the guest's owning virtualization host
  and canonical PVE device. The resolver fails closed when that relationship is
  missing or ambiguous instead of falling back to the guest's address.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @proxmox_provider "proxmox"
  @proxmox_target_kinds [:pve_host, :qemu_guest, :lxc_guest]
  @proxmox_console_modes [:ssh, :proxmox_termproxy, :proxmox_vncwebsocket]
  @proxmox_enabled_console_modes [:ssh, :proxmox_termproxy, :proxmox_vncwebsocket]

  @type proxmox_controller :: %{
          device: map(),
          device_uid: String.t(),
          provider_ref: String.t() | nil,
          integration_id: String.t() | nil,
          cluster: String.t() | nil,
          cluster_id: String.t() | nil,
          node: String.t(),
          hostname: String.t() | nil,
          ip: String.t() | nil,
          base_url: String.t(),
          ssh_port: pos_integer(),
          agent_id: String.t() | nil,
          gateway_id: String.t() | nil
        }

  @type proxmox_target :: %{
          target_kind: :pve_host | :qemu_guest | :lxc_guest,
          console_mode: :ssh | :proxmox_termproxy | :proxmox_vncwebsocket,
          provider_ref: String.t() | nil,
          integration_id: String.t() | nil,
          node: String.t(),
          vmid: integer() | nil,
          cluster: String.t() | nil,
          controller: proxmox_controller()
        }

  @doc """
  Resolves a Proxmox console target from a canonical device and request.

  Tests may inject the inventory lookups. Production lookups are system-scoped
  by the caller so resolving the controller does not widen the requesting
  user's inventory permissions.
  """
  @spec resolve_proxmox(map(), map(), keyword()) :: {:ok, proxmox_target()} | {:error, atom()}
  def resolve_proxmox(device, request, opts \\ []) when is_map(device) and is_map(request) do
    ash_opts = Keyword.get(opts, :ash_opts, [])
    virtualization_lookup = Keyword.get(opts, :virtualization_lookup, &virtualization_by_device/3)
    host_lookup = Keyword.get(opts, :host_lookup, &virtualization_host_by_id/2)
    device_lookup = Keyword.get(opts, :device_lookup, &device_by_uid/2)
    identity_scope = normalize_identity_scope(Keyword.get(opts, :identity_scope))

    requested_kind =
      normalize_target_kind(Map.get(request, :target_kind) || Map.get(request, "target_kind"))

    requested_mode =
      normalize_console_mode(Map.get(request, :console_mode) || Map.get(request, "console_mode"))

    with {:ok, inventory_target} <-
           resolve_inventory_target(
             device,
             ash_opts,
             virtualization_lookup,
             host_lookup,
             device_lookup,
             identity_scope
           ),
         {:ok, target_kind} <- pick_target_kind(requested_kind, inventory_target.target_kind),
         {:ok, console_mode} <- pick_console_mode(requested_mode, target_kind) do
      {:ok,
       inventory_target
       |> Map.put(:target_kind, target_kind)
       |> Map.put(:console_mode, console_mode)}
    end
  end

  defp resolve_inventory_target(
         device,
         ash_opts,
         virtualization_lookup,
         host_lookup,
         device_lookup,
         identity_scope
       ) do
    case virtualization_lookup.(VirtualizationHost, device_uid(device), ash_opts) do
      {:ok, hosts} when is_list(hosts) ->
        case select_or_complete_proxmox_row(hosts, device, identity_scope) do
          {:ok, host} ->
            build_host_target(host, device)

          {:error, :not_found} ->
            resolve_guest_target(
              device,
              ash_opts,
              virtualization_lookup,
              host_lookup,
              device_lookup,
              identity_scope
            )

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _reason} ->
        {:error, :console_inventory_unavailable}

      _other ->
        {:error, :unsupported_console_target}
    end
  end

  defp resolve_guest_target(
         device,
         ash_opts,
         virtualization_lookup,
         host_lookup,
         device_lookup,
         identity_scope
       ) do
    case virtualization_lookup.(VirtualizationGuest, device_uid(device), ash_opts) do
      {:ok, guests} when is_list(guests) ->
        case select_or_complete_proxmox_row(guests, device, identity_scope) do
          {:ok, guest} ->
            build_guest_target(guest, ash_opts, host_lookup, device_lookup, identity_scope)

          {:error, :not_found} ->
            {:error, :unsupported_console_target}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _reason} ->
        {:error, :console_inventory_unavailable}

      _other ->
        {:error, :unsupported_console_target}
    end
  end

  defp build_guest_target(guest, ash_opts, host_lookup, device_lookup, identity_scope) do
    with {:ok, host_id} <- required_string(guest, [:host_id, "host_id"]),
         {:ok, host} <- normalize_lookup_result(host_lookup.(host_id, ash_opts)),
         {:ok, host} <- maybe_complete_legacy_row(host, identity_scope),
         :ok <- ensure_authoritative_owner(guest, host),
         {:ok, controller_device_uid} <- required_string(host, [:device_uid, "device_uid"]),
         {:ok, controller_device} <-
           normalize_lookup_result(device_lookup.(controller_device_uid, ash_opts)),
         {:ok, controller} <- build_controller(host, controller_device) do
      integration_id = row_integration_id(guest)

      {:ok,
       %{
         target_kind: guest_target_kind(guest),
         provider_ref: value_string(guest, [:provider_ref, "provider_ref"]),
         integration_id: integration_id,
         identity_version: 3,
         identity_state: :authoritative,
         controller_id: value_string(guest, [:controller_id, "controller_id"]),
         native_cluster_id: value_string(guest, [:native_cluster_id, "native_cluster_id"]),
         object_kind: value_string(guest, [:object_kind, "object_kind"]),
         native_object_id: value_string(guest, [:native_object_id, "native_object_id"]),
         provider_instance_ref:
           value_string(guest, [:provider_instance_ref, "provider_instance_ref"]),
         inventory_row_id: value_string(guest, [:id, "id"]),
         owner_host_id: host_id,
         node: controller.node,
         vmid: value_integer(guest, [:vmid, "vmid"]),
         cluster: row_cluster(guest) || controller.cluster,
         controller: controller
       }}
    else
      {:error, :not_found} -> {:error, :console_controller_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_host_target(host, device) do
    with true <- authoritative_proxmox_row?(host),
         {:ok, controller} <- build_controller(host, device) do
      integration_id = row_integration_id(host)

      {:ok,
       %{
         target_kind: :pve_host,
         provider_ref: value_string(host, [:provider_ref, "provider_ref"]),
         integration_id: integration_id,
         identity_version: 3,
         identity_state: :authoritative,
         controller_id: value_string(host, [:controller_id, "controller_id"]),
         native_cluster_id: value_string(host, [:native_cluster_id, "native_cluster_id"]),
         object_kind: value_string(host, [:object_kind, "object_kind"]),
         native_object_id: value_string(host, [:native_object_id, "native_object_id"]),
         provider_instance_ref:
           value_string(host, [:provider_instance_ref, "provider_instance_ref"]),
         inventory_row_id: value_string(host, [:id, "id"]),
         owner_host_id: value_string(host, [:id, "id"]),
         node: controller.node,
         vmid: nil,
         cluster: row_cluster(host) || controller.cluster,
         controller: controller
       }}
    else
      false -> {:error, :unsupported_console_target}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_controller(host, device) do
    host_metadata = value_map(host, [:metadata, "metadata"])
    device_metadata = value_map(device, [:metadata, "metadata"])

    node = value_string(host, [:name, "name"])
    hostname = value_string(device, [:hostname, "hostname", :name, "name"]) || node

    ip =
      value_string(device, [:ip, "ip"]) ||
        value_string(host_metadata, [:ip, "ip", :management_ip, "management_ip"])

    with {:ok, device_uid} <- required_string(device, [:uid, "uid", :device_uid, "device_uid"]),
         {:ok, node} <- present_string(node),
         {:ok, base_url} <- controller_base_url(ip, hostname, host_metadata, device_metadata) do
      integration_id = row_integration_id(host)

      {:ok,
       %{
         device: device,
         device_uid: device_uid,
         provider_ref: value_string(host, [:provider_ref, "provider_ref"]),
         integration_id: integration_id,
         identity_version: 3,
         identity_state: :authoritative,
         controller_id: value_string(host, [:controller_id, "controller_id"]),
         native_cluster_id: value_string(host, [:native_cluster_id, "native_cluster_id"]),
         object_kind: value_string(host, [:object_kind, "object_kind"]),
         native_object_id: value_string(host, [:native_object_id, "native_object_id"]),
         provider_instance_ref:
           value_string(host, [:provider_instance_ref, "provider_instance_ref"]),
         virtualization_host_id: value_string(host, [:id, "id"]),
         cluster: row_cluster(host),
         cluster_id: value_string(host, [:cluster_id, "cluster_id"]),
         node: node,
         hostname: hostname,
         ip: ip,
         base_url: base_url,
         ssh_port: positive_int(device_metadata, [:ssh_port, "ssh_port"], 22),
         agent_id: controller_agent_id(device),
         gateway_id: value_string(device, [:gateway_id, "gateway_id"])
       }}
    else
      {:error, :not_found} -> {:error, :console_controller_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp controller_base_url(ip, _hostname, host_metadata, device_metadata) do
    endpoint = canonical_ip_endpoint(ip)

    explicit_url =
      value_string(device_metadata, [
        :proxmox_base_url,
        "proxmox_base_url",
        :base_url,
        "base_url",
        :api_url,
        "api_url"
      ]) ||
        value_string(host_metadata, [
          :proxmox_base_url,
          "proxmox_base_url",
          :base_url,
          "base_url",
          :api_url,
          "api_url"
        ])

    cond do
      is_nil(endpoint) ->
        {:error, :console_controller_endpoint_missing}

      is_binary(explicit_url) ->
        canonical_controller_origin(explicit_url, endpoint)

      true ->
        default_controller_origin(endpoint)
    end
  end

  defp canonical_controller_origin(raw, endpoint) do
    case URI.parse(String.trim(raw)) do
      %URI{
        scheme: "https",
        authority: authority,
        host: host,
        port: port,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and path in [nil, "", "/"] ->
        effective_port = port || URI.default_port("https")

        cond do
          not is_integer(effective_port) or effective_port < 1 or effective_port > 65_535 ->
            {:error, :invalid_controller_origin}

          not valid_origin_authority?(authority, host, effective_port) ->
            {:error, :invalid_controller_origin}

          not valid_ip_address?(normalize_endpoint(host)) ->
            {:error, :invalid_controller_origin}

          not same_endpoint?(host, endpoint) ->
            {:error, :controller_origin_mismatch}

          true ->
            {:ok, URI.to_string(%URI{scheme: "https", host: host, port: effective_port})}
        end

      _other ->
        {:error, :invalid_controller_origin}
    end
  end

  defp valid_origin_authority?(authority, host, port)
       when is_binary(authority) and is_binary(host) and is_integer(port) do
    authority = String.downcase(authority)
    host = String.downcase(host)

    allowed =
      if String.contains?(host, ":") do
        ["[#{host}]", "[#{host}]:#{port}"]
      else
        [host, "#{host}:#{port}"]
      end

    authority in allowed
  end

  defp valid_origin_authority?(_authority, _host, _port), do: false

  defp default_controller_origin(endpoint) do
    {:ok, URI.to_string(%URI{scheme: "https", host: endpoint, port: 8006})}
  end

  defp same_endpoint?(left, right) do
    normalize_endpoint(left) == normalize_endpoint(right)
  end

  defp normalize_endpoint(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.downcase()
  end

  defp canonical_ip_endpoint(value) when is_binary(value) do
    endpoint = normalize_endpoint(value)

    if valid_ip_address?(endpoint), do: endpoint
  end

  defp canonical_ip_endpoint(_value), do: nil

  defp valid_ip_address?(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, _address} -> true
      {:error, _reason} -> false
    end
  end

  defp select_proxmox_row(rows, device) do
    candidates = Enum.filter(rows, &authoritative_proxmox_row?/1)
    requested_identities = device_identity_values(device)

    exact =
      Enum.filter(candidates, fn row ->
        not MapSet.disjoint?(requested_identities, row_identity_values(row))
      end)

    case exact do
      [row] -> {:ok, row}
      [_first, _second | _rest] -> {:error, :ambiguous_console_target}
      [] -> select_single_candidate(candidates)
    end
  end

  defp select_or_complete_proxmox_row(rows, device, identity_scope) do
    case select_proxmox_row(rows, device) do
      {:ok, _row} = ok ->
        ok

      {:error, :not_found} ->
        complete_legacy_proxmox_row(rows, device, identity_scope)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_legacy_proxmox_row(_rows, _device, nil), do: {:error, :not_found}

  defp complete_legacy_proxmox_row(rows, device, identity_scope) do
    candidates = Enum.filter(rows, &completable_legacy_proxmox_row?/1)
    requested_identities = device_identity_values(device)

    exact =
      Enum.filter(candidates, fn row ->
        not MapSet.disjoint?(requested_identities, row_identity_values(row))
      end)

    selected =
      case exact do
        [row] -> {:ok, row}
        [_first, _second | _rest] -> {:error, :ambiguous_console_target}
        [] -> select_single_candidate(candidates)
      end

    case selected do
      {:ok, row} -> complete_row_identity(row, identity_scope)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_complete_legacy_row(row, identity_scope) do
    cond do
      authoritative_proxmox_row?(row) ->
        {:ok, row}

      completable_legacy_proxmox_row?(row) ->
        complete_row_identity(row, identity_scope)

      true ->
        {:ok, row}
    end
  end

  defp complete_row_identity(_row, nil), do: {:error, :not_found}

  defp complete_row_identity(row, identity_scope) do
    native_cluster_id = value_string(row, [:native_cluster_id, "native_cluster_id"])
    object_kind = value_string(row, [:object_kind, "object_kind"])
    native_object_id = value_string(row, [:native_object_id, "native_object_id"])

    case IntegrationIdentity.proxmox_v3_fields(
           identity_scope.integration_id,
           identity_scope.controller_id,
           native_cluster_id,
           object_kind,
           native_object_id
         ) do
      {:ok, identity} ->
        completed = merge_identity_into_row(row, identity)

        if authoritative_proxmox_row?(completed),
          do: {:ok, completed},
          else: {:error, :unsupported_console_target}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp completable_legacy_proxmox_row?(row) do
    value_string(row, [:provider, "provider"]) == @proxmox_provider and
      not authoritative_proxmox_row?(row) and
      present_value(value_string(row, [:native_cluster_id, "native_cluster_id"])) != nil and
      value_string(row, [:object_kind, "object_kind"]) in ["cluster", "node", "qemu", "lxc"] and
      present_value(value_string(row, [:native_object_id, "native_object_id"])) != nil
  end

  defp merge_identity_into_row(row, identity) when is_struct(row) do
    struct(row, identity)
  end

  defp merge_identity_into_row(row, identity) when is_map(row) do
    Map.merge(row, identity)
  end

  defp normalize_identity_scope(%{integration_id: integration_id, controller_id: controller_id}) do
    with {:ok, integration_id} <- present_string(integration_id),
         {:ok, controller_id} <- present_string(controller_id) do
      %{integration_id: integration_id, controller_id: controller_id}
    else
      _ -> nil
    end
  end

  defp normalize_identity_scope(_scope), do: nil

  defp select_single_candidate([row]), do: {:ok, row}
  defp select_single_candidate([]), do: {:error, :not_found}
  defp select_single_candidate(_rows), do: {:error, :ambiguous_console_target}

  defp device_identity_values(device) do
    metadata = value_map(device, [:metadata, "metadata"])

    identity_set([
      v3_object_identity(value_string(metadata, [:integration_id, "integration_id"])),
      v3_object_identity(
        value_string(metadata, [:hypervisor_provider_ref, "hypervisor_provider_ref"])
      ),
      v3_object_identity(
        value_string(metadata, [:hypervisor_host_provider_ref, "hypervisor_host_provider_ref"])
      ),
      v3_object_identity(value_string(metadata, [:provider_ref, "provider_ref"])),
      v3_instance_identity(
        value_string(metadata, [:provider_instance_ref, "provider_instance_ref"])
      ),
      scoped_identity(metadata)
    ])
  end

  defp row_identity_values(row) do
    identity_set([
      value_string(row, [:provider_ref, "provider_ref"]),
      value_string(row, [:provider_instance_ref, "provider_instance_ref"]),
      scoped_identity(row)
    ])
  end

  defp identity_set(values) do
    values
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> MapSet.new()
  end

  defp row_integration_id(row) do
    value_string(row, [:integration_id, "integration_id"])
  end

  defp v3_object_identity(value) when is_binary(value) do
    if IntegrationIdentity.v3?(value), do: value
  end

  defp v3_object_identity(_value), do: nil

  defp v3_instance_identity("proxmox:v3:" <> _rest = value), do: value
  defp v3_instance_identity(_value), do: nil

  defp scoped_identity(row) do
    metadata = value_map(row, [:metadata, "metadata"])

    integration_id =
      value_string(row, [:integration_id, "integration_id"]) ||
        value_string(metadata, [:integration_id, "integration_id"])

    controller_id =
      value_string(row, [:controller_id, "controller_id"]) ||
        value_string(metadata, [:controller_id, "controller_id"])

    native_cluster_id =
      value_string(row, [:native_cluster_id, "native_cluster_id"]) ||
        value_string(metadata, [:native_cluster_id, "native_cluster_id"])

    if Enum.all?([integration_id, controller_id, native_cluster_id], &present_value/1) do
      "scope:#{integration_id}:#{controller_id}:#{native_cluster_id}"
    end
  end

  defp row_cluster(row) do
    value_string(row, [:native_cluster_id, "native_cluster_id"]) ||
      row
      |> value_map([:metadata, "metadata"])
      |> value_string([:native_cluster_id, "native_cluster_id"]) ||
      cluster_name(value_string(row, [:provider_ref, "provider_ref"]))
  end

  defp cluster_name(integration_id) do
    case IntegrationIdentity.parse_v3(integration_id) do
      {:ok, %{native_cluster_id: cluster}} ->
        cluster

      :error ->
        nil
    end
  end

  defp virtualization_by_device(resource, device_uid, ash_opts) do
    resource
    |> Ash.Query.for_read(:by_device, %{device_uid: device_uid})
    |> Ash.read(ash_opts)
  end

  defp virtualization_host_by_id(host_id, ash_opts) do
    VirtualizationHost
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(id == ^host_id)
    |> Ash.read_one(ash_opts)
  end

  defp device_by_uid(device_uid, ash_opts), do: Device.get_by_uid(device_uid, false, ash_opts)

  defp normalize_lookup_result({:ok, nil}), do: {:error, :not_found}
  defp normalize_lookup_result({:ok, value}) when is_map(value), do: {:ok, value}
  defp normalize_lookup_result({:error, reason}), do: {:error, reason}
  defp normalize_lookup_result(_result), do: {:error, :not_found}

  defp authoritative_proxmox_row?(row) do
    value_string(row, [:provider, "provider"]) == @proxmox_provider and
      value_integer(row, [:identity_version, "identity_version"]) == 3 and
      value_string(row, [:identity_state, "identity_state"]) == "authoritative" and
      IntegrationIdentity.validate_v3_record(row) == :ok
  end

  defp ensure_authoritative_owner(guest, host) do
    if authoritative_proxmox_row?(guest) and authoritative_proxmox_row?(host) and
         same_authority_scope?(guest, host),
       do: :ok,
       else: {:error, :console_controller_not_found}
  end

  defp same_authority_scope?(left, right) do
    Enum.all?(
      [:integration_id, :controller_id, :native_cluster_id, :provider_instance_ref],
      fn key ->
        value_string(left, [key, Atom.to_string(key)]) ==
          value_string(right, [key, Atom.to_string(key)])
      end
    )
  end

  defp guest_target_kind(row) do
    case value_string(row, [:guest_type, "guest_type"]) do
      guest_type when guest_type in ["lxc", "container"] -> :lxc_guest
      _guest_type -> :qemu_guest
    end
  end

  defp pick_target_kind(nil, inferred), do: {:ok, inferred}
  defp pick_target_kind(kind, kind) when kind in @proxmox_target_kinds, do: {:ok, kind}
  defp pick_target_kind(_requested, _inferred), do: {:error, :unsupported_console_target}

  defp pick_console_mode(nil, :pve_host), do: {:ok, :proxmox_termproxy}
  defp pick_console_mode(nil, :lxc_guest), do: {:ok, :proxmox_termproxy}
  defp pick_console_mode(nil, :qemu_guest), do: {:ok, :proxmox_vncwebsocket}

  defp pick_console_mode(:ssh, :pve_host) when :ssh in @proxmox_enabled_console_modes,
    do: {:ok, :ssh}

  defp pick_console_mode(:proxmox_termproxy, target_kind)
       when target_kind in [:pve_host, :lxc_guest] and
              :proxmox_termproxy in @proxmox_enabled_console_modes,
       do: {:ok, :proxmox_termproxy}

  defp pick_console_mode(:proxmox_vncwebsocket, :qemu_guest)
       when :proxmox_vncwebsocket in @proxmox_enabled_console_modes,
       do: {:ok, :proxmox_vncwebsocket}

  defp pick_console_mode(mode, _target_kind) when mode in @proxmox_console_modes,
    do: {:error, :unsupported_console_mode}

  defp pick_console_mode(_mode, _target_kind), do: {:error, :unsupported_console_mode}

  defp normalize_target_kind(value) when is_atom(value) and value in @proxmox_target_kinds,
    do: value

  defp normalize_target_kind("pve_host"), do: :pve_host
  defp normalize_target_kind("qemu_guest"), do: :qemu_guest
  defp normalize_target_kind("lxc_guest"), do: :lxc_guest
  defp normalize_target_kind(_value), do: nil

  defp normalize_console_mode(value) when is_atom(value) and value in @proxmox_console_modes,
    do: value

  defp normalize_console_mode("ssh"), do: :ssh
  defp normalize_console_mode("proxmox_termproxy"), do: :proxmox_termproxy
  defp normalize_console_mode("proxmox_vncwebsocket"), do: :proxmox_vncwebsocket
  defp normalize_console_mode(_value), do: nil

  defp controller_agent_id(device) do
    value_string(device, [:agent_id, "agent_id"]) ||
      device
      |> value_map([:metadata, "metadata"])
      |> value_string([
        :sync_service_id,
        "sync_service_id",
        :agent_id,
        "agent_id",
        :source_agent_id,
        "source_agent_id",
        :discovered_by_agent_id,
        "discovered_by_agent_id"
      ])
  end

  defp required_string(map, keys), do: map |> value_string(keys) |> present_string()

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :not_found}
      trimmed -> {:ok, trimmed}
    end
  end

  defp present_string(_value), do: {:error, :not_found}

  defp present_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_value(_value), do: nil

  defp positive_int(map, keys, default) do
    case ValueUtils.int_value(map, keys, default) do
      value when is_integer(value) and value > 0 and value <= 65_535 -> value
      _value -> default
    end
  end

  defp device_uid(device), do: value_string(device, [:uid, "uid", :device_uid, "device_uid"])

  defp value_string(map, keys) when is_map(map), do: ValueUtils.string_value(map, keys)
  defp value_string(_map, _keys), do: nil

  defp value_map(map, keys) when is_map(map), do: ValueUtils.map_value(map, keys) || %{}
  defp value_map(_map, _keys), do: %{}

  defp value_integer(map, keys) do
    case ValueUtils.int_value(map, keys, nil) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end
end
