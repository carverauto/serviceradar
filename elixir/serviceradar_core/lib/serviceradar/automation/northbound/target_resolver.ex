defmodule ServiceRadar.Automation.Northbound.TargetResolver do
  @moduledoc """
  Resolves device, interface, and event action targets into immutable snapshots.

  Invocations keep target snapshots so later provider execution and audit
  history are tied to the selected inventory state, even if the device or
  interface changes after launch.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface

  require Ash.Query

  @type target_spec :: map()

  @spec resolve_targets([target_spec()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def resolve_targets(targets, opts \\ [])

  def resolve_targets(targets, opts) when is_list(targets) do
    actor = Keyword.get(opts, :actor)

    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      case resolve_target(target, actor) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_targets(_targets, _opts), do: {:error, :invalid_targets}

  defp resolve_target(target, actor) when is_map(target) do
    case normalize_kind(fetch(target, :kind)) do
      :device -> resolve_device_target(target, actor)
      :interface -> resolve_interface_target(target, actor)
      :event -> resolve_event_target(target)
      _ -> {:error, {:unsupported_target_kind, fetch(target, :kind)}}
    end
  end

  defp resolve_target(_target, _actor), do: {:error, :invalid_target}

  defp resolve_device_target(target, actor) do
    with {:ok, uid} <- required_string(target, :device_uid),
         {:ok, device} <- fetch_device(uid, actor) do
      {:ok, device_snapshot(device)}
    end
  end

  defp resolve_interface_target(target, actor) do
    with {:ok, device_uid} <- required_string(target, :device_uid),
         {:ok, interface_uid} <- required_string(target, :interface_uid),
         {:ok, device} <- fetch_device(device_uid, actor),
         {:ok, interface} <- fetch_interface(device_uid, interface_uid, actor) do
      {:ok, interface_snapshot(device, interface)}
    end
  end

  defp resolve_event_target(target) do
    with {:ok, event_id} <- required_string(target, :event_id) do
      {:ok,
       %{
         "kind" => "event",
         "event_id" => event_id,
         "attributes" => normalize_map(fetch(target, :attributes))
       }}
    end
  end

  defp fetch_device(uid, actor) do
    Device
    |> Ash.Query.for_read(:by_uid, %{uid: uid, include_deleted: false}, actor: actor)
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Inventory)
    |> case do
      {:ok, nil} -> {:error, {:device_not_found, uid}}
      {:ok, device} -> {:ok, device}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_interface(device_uid, interface_uid, actor) do
    Interface
    |> Ash.Query.for_read(
      :by_device_and_uid,
      %{device_id: device_uid, interface_uid: interface_uid},
      actor: actor
    )
    |> Ash.Query.sort(timestamp: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(actor: actor, domain: ServiceRadar.Inventory)
    |> case do
      {:ok, []} -> {:error, {:interface_not_found, device_uid, interface_uid}}
      {:ok, [interface | _]} -> {:ok, interface}
      {:error, error} -> {:error, error}
    end
  end

  defp device_snapshot(device) do
    %{
      "kind" => "device",
      "device_uid" => device.uid,
      "name" => device.name,
      "hostname" => device.hostname,
      "ip" => device.ip,
      "mac" => device.mac,
      "vendor_name" => device.vendor_name,
      "model" => device.model,
      "type" => device.type,
      "is_available" => device.is_available,
      "agent_id" => device.agent_id,
      "gateway_id" => device.gateway_id,
      "discovery_sources" => device.discovery_sources || []
    }
  end

  defp interface_snapshot(device, interface) do
    if_name = first_present([interface.if_name, interface.if_descr, interface.interface_uid])

    Map.merge(
      %{
        "kind" => "interface",
        "device_uid" => device.uid,
        "device_name" => device.name,
        "device_hostname" => device.hostname,
        "device_ip" => device.ip,
        "device_agent_id" => device.agent_id,
        "device_gateway_id" => device.gateway_id,
        "interface_uid" => interface.interface_uid,
        "if_index" => interface.if_index,
        "ifIndex" => interface.if_index,
        "ifindex" => interface.if_index,
        "if_name" => interface.if_name,
        "interface_name" => if_name,
        "name" => if_name,
        "if_descr" => interface.if_descr,
        "if_alias" => interface.if_alias,
        "if_phys_address" => interface.if_phys_address,
        "ip_addresses" => interface.ip_addresses || [],
        "if_admin_status" => interface_status_name(interface.if_admin_status),
        "if_admin_status_id" => interface.if_admin_status,
        "if_oper_status" => interface_status_name(interface.if_oper_status),
        "if_oper_status_id" => interface.if_oper_status,
        "if_type_name" => interface.if_type_name,
        "interface_kind" => interface.interface_kind,
        "classifications" => interface.classifications || []
      },
      interface_physical_context(interface, if_name)
    )
  end

  defp interface_physical_context(interface, if_name) do
    source_name =
      first_present([if_name, interface.if_descr, interface.if_alias, interface.interface_uid])

    parsed = parse_physical_interface_name(source_name)

    context =
      %{}
      |> merge_present("name", source_name)
      |> merge_present("path", Map.get(parsed, "physical_path"))
      |> merge_present("stack_member", Map.get(parsed, "stack_member"))
      |> merge_present("module", Map.get(parsed, "module"))
      |> merge_present("slot", Map.get(parsed, "slot"))
      |> merge_present("port", Map.get(parsed, "port"))

    %{
      "physical_name" => source_name,
      "physical_path" => Map.get(parsed, "physical_path"),
      "stack_member" => Map.get(parsed, "stack_member"),
      "module" => Map.get(parsed, "module"),
      "slot" => Map.get(parsed, "slot"),
      "port" => Map.get(parsed, "port"),
      "physical_context" => context
    }
  end

  defp parse_physical_interface_name(value) when is_binary(value) do
    segments =
      ~r/\d+/
      |> Regex.scan(value)
      |> List.flatten()

    case segments do
      [port] ->
        %{"physical_path" => port, "port" => port}

      [module, port] ->
        %{
          "physical_path" => Enum.join([module, port], "/"),
          "module" => module,
          "slot" => module,
          "port" => port
        }

      [stack_member, module, port | _rest] ->
        %{
          "physical_path" => Enum.join([stack_member, module, port], "/"),
          "stack_member" => stack_member,
          "module" => module,
          "slot" => module,
          "port" => port
        }

      _ ->
        %{}
    end
  end

  defp parse_physical_interface_name(_value), do: %{}

  defp interface_status_name(1), do: "up"
  defp interface_status_name(2), do: "down"
  defp interface_status_name(3), do: "testing"
  defp interface_status_name(nil), do: nil
  defp interface_status_name(value), do: to_string(value)

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp first_present(values) when is_list(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end)
  end

  defp merge_present(map, _key, nil), do: map
  defp merge_present(map, _key, ""), do: map
  defp merge_present(map, key, value), do: Map.put(map, key, value)

  defp required_string(map, key) do
    case fetch(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:missing_target_field, key}}, else: {:ok, value}

      _ ->
        {:error, {:missing_target_field, key}}
    end
  end

  defp normalize_kind(value) when is_atom(value), do: value

  defp normalize_kind(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "device" -> :device
      "interface" -> :interface
      "event" -> :event
      _ -> nil
    end
  end

  defp normalize_kind(_value), do: nil

  defp normalize_map(%{} = value), do: value
  defp normalize_map(_value), do: %{}
end
