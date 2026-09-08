defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Targeting do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface

  def assign_target_preview(socket, target_query) do
    scope = socket.assigns.current_scope

    is_default =
      case socket.assigns.selected_profile do
        %{is_default: true} -> true
        _ -> false
      end

    normalized_query = normalize_target_query(target_query, is_default)

    if is_nil(normalized_query) do
      socket
      |> assign(:target_device_count, nil)
      |> assign(:target_entity, "devices")
    else
      target_entity = extract_srql_entity(normalized_query)
      device_count = count_target_devices(scope, normalized_query)

      socket
      |> assign(:target_device_count, device_count)
      |> assign(:target_entity, target_entity)
    end
  end

  def normalize_target_query(target_query, is_default) do
    cond do
      target_query in [nil, ""] and is_default ->
        "in:devices"

      target_query in [nil, ""] ->
        nil

      true ->
        normalize_target_query(target_query)
    end
  end

  def normalize_target_query(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" ->
        "in:devices"

      String.starts_with?(query, "in:") ->
        query

      true ->
        "in:devices " <> query
    end
  end

  def normalize_target_query(_), do: nil

  def format_target_count({:ok, count}) do
    label = if count == 1, do: "target", else: "targets"
    "#{count} #{label}"
  end

  def format_target_count(_), do: "Unknown"

  def target_count_title({:ok, _count}), do: nil
  def target_count_title(_), do: "Target count unavailable"

  def profile_target_query(profile) do
    target_query = resolve_target_query(profile.target_query, profile.is_default)
    normalize_target_query(target_query, profile.is_default)
  end

  # Resolve target query for a profile, using defaults for default profiles
  def resolve_target_query(nil, true), do: "in:devices"
  def resolve_target_query("", true), do: "in:devices"
  def resolve_target_query(nil, _is_default), do: nil
  def resolve_target_query("", _is_default), do: ""
  def resolve_target_query(query, _is_default), do: query

  def count_target_devices(_scope, nil), do: :unknown
  def count_target_devices(_scope, ""), do: :unknown

  def count_target_devices(scope, target_query) when is_binary(target_query) do
    # Parse the SRQL query and count matching targets based on entity type
    entity = extract_srql_entity(target_query)

    with {:ok, ast_json} <- ServiceRadarSRQL.Native.parse_ast(target_query),
         {:ok, ast} <- Jason.decode(ast_json) do
      count_entity_from_ast(scope, entity, ast)
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  # Helper to count entities from parsed AST (extracted to reduce nesting depth)
  def count_entity_from_ast(scope, entity, ast) do
    case entity do
      "devices" -> count_devices_from_ast(scope, ast)
      "interfaces" -> count_interfaces_from_ast(scope, ast)
      _ -> count_devices_from_ast(scope, ast)
    end
  end

  def extract_srql_entity(query) when is_binary(query) do
    query = String.trim(query)

    case Regex.run(~r/^in:(\S+)/, query) do
      [_, entity] -> String.downcase(entity)
      _ -> "devices"
    end
  end

  def extract_srql_entity(_), do: "devices"

  def count_devices_from_ast(scope, ast) do
    filters = extract_srql_filters(ast)

    query =
      Device
      |> Ash.Query.for_read(:read, %{})
      |> apply_device_filters(filters)

    case query do
      {:error, :unsupported_filter} ->
        :unknown

      query ->
        case Ash.count(query, scope: scope) do
          {:ok, count} -> {:ok, count}
          _ -> :unknown
        end
    end
  rescue
    _ -> :unknown
  end

  def count_interfaces_from_ast(scope, ast) do
    filters = extract_srql_filters(ast)

    query =
      Interface
      |> Ash.Query.for_read(:read, %{})
      |> apply_interface_filters(filters)

    case query do
      {:error, :unsupported_filter} ->
        :unknown

      query ->
        # This is a DEVICE count, not an interface count -- "N targets" means the
        # number of devices SNMP polling would target, and a device with twelve
        # matching interfaces is one target. The distinct is what makes it one.
        #
        # It also happens to hide the append-only bloat in discovered_interfaces
        # (~98 rows per interface state), and that WAS the original reason.
        # refactor-interface-observation-persistence removes the bloat, at which
        # point that reason evaporates and this line starts looking redundant.
        # It is not: delete it and the number silently changes from devices to
        # interfaces, which for a switch is a factor of hundreds.
        query = Ash.Query.distinct(query, :device_id)

        case Ash.count(query, scope: scope) do
          {:ok, count} -> {:ok, count}
          _ -> :unknown
        end
    end
  rescue
    _ -> :unknown
  end

  def apply_device_filters(query, filters) do
    Enum.reduce_while(filters, query, fn filter, q ->
      case apply_device_filter(q, filter) do
        {:ok, updated} -> {:cont, updated}
        {:error, :unsupported_filter} -> {:halt, {:error, :unsupported_filter}}
      end
    end)
  end

  def apply_device_filter(query, %{field: field, op: op, value: value}) when is_binary(field) do
    case map_device_field(field) do
      nil -> {:error, :unsupported_filter}
      mapped_field -> {:ok, apply_field_filter(query, mapped_field, op, value)}
    end
  rescue
    _ -> {:error, :unsupported_filter}
  end

  def apply_device_filter(_query, _), do: {:error, :unsupported_filter}

  @device_srql_field_mapping %{
    "uid" => :uid,
    "device_id" => :uid,
    "hostname" => :hostname,
    "name" => :name,
    "ip" => :ip,
    "gateway_id" => :gateway_id,
    "agent_id" => :agent_id,
    "vendor_name" => :vendor_name,
    "model" => :model,
    "type" => :type,
    "type_id" => :type_id
  }

  def map_device_field(field), do: Map.get(@device_srql_field_mapping, field)

  def extract_srql_filters(%{"filters" => filters}) when is_list(filters) do
    Enum.map(filters, fn filter ->
      %{
        field: Map.get(filter, "field"),
        op: Map.get(filter, "op", "eq"),
        value: Map.get(filter, "value")
      }
    end)
  end

  def extract_srql_filters(_), do: []

  def apply_interface_filters(query, filters) do
    Enum.reduce_while(filters, query, fn filter, q ->
      case apply_interface_filter(q, filter) do
        {:ok, updated} -> {:cont, updated}
        {:error, :unsupported_filter} -> {:halt, {:error, :unsupported_filter}}
      end
    end)
  end

  def apply_interface_filter(query, %{field: field, op: op, value: value}) when is_binary(field) do
    case map_srql_field(field) do
      nil -> {:error, :unsupported_filter}
      mapped_field -> {:ok, apply_field_filter(query, mapped_field, op, value)}
    end
  rescue
    _ -> {:error, :unsupported_filter}
  end

  def apply_interface_filter(_query, _), do: {:error, :unsupported_filter}

  # Map SRQL interface fields to Ash attributes
  @srql_field_mapping %{
    "if_name" => :if_name,
    "name" => :if_name,
    "if_descr" => :if_descr,
    "description" => :if_descr,
    "if_alias" => :if_alias,
    "alias" => :if_alias,
    "device_id" => :device_id,
    "device_ip" => :device_ip,
    "ip" => :device_ip,
    "gateway_id" => :gateway_id,
    "agent_id" => :agent_id,
    "if_oper_status" => :if_oper_status,
    "oper_status" => :if_oper_status,
    "if_admin_status" => :if_admin_status,
    "admin_status" => :if_admin_status,
    "if_speed" => :if_speed,
    "speed" => :if_speed,
    "if_phys_address" => :if_phys_address,
    "mac" => :if_phys_address
  }

  def map_srql_field(field), do: Map.get(@srql_field_mapping, field)

  # Apply filter based on SRQL operator
  # Supports both UI operators (equals, contains) and legacy operators (eq, like)
  def apply_field_filter(query, field, op, value) when op in ["eq", "equals"] do
    Ash.Query.filter_input(query, %{field => %{eq: value}})
  end

  def apply_field_filter(query, field, op, value) when op in ["not_eq", "not_equals"] do
    Ash.Query.filter_input(query, %{field => %{not_eq: value}})
  end

  def apply_field_filter(query, field, "contains", value) do
    Ash.Query.filter_input(query, %{field => %{contains: value}})
  end

  def apply_field_filter(query, field, "like", value) do
    # Legacy SRQL "like" values contain % wildcards, strip them for Ash contains
    stripped = value |> String.trim_leading("%") |> String.trim_trailing("%")
    Ash.Query.filter_input(query, %{field => %{contains: stripped}})
  end

  def apply_field_filter(query, _field, op, _value) when op in ["not_like", "not_contains"] do
    # Skip negative contains - count will be an approximation
    # Ash doesn't have a direct not_contains filter
    query
  end

  def apply_field_filter(query, field, _op, value) do
    # Default to equality for unknown operators
    Ash.Query.filter_input(query, %{field => %{eq: value}})
  end
end
