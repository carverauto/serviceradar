defmodule ServiceRadar.Plugins.PluginInputPayloadBuilder do
  @moduledoc """
  Builds `serviceradar.plugin_inputs.v1` payloads from resolved SRQL input rows.

  This is the first-class control-plane path for converting server-side query
  results (devices, interfaces, and future entities) into bounded assignment
  payloads for plugins.
  """

  alias ServiceRadar.Plugins.PluginInputs

  @type resolved_input :: %{
          required(:name) => String.t(),
          required(:entity) => String.t(),
          required(:query) => String.t(),
          required(:rows) => [map()]
        }

  @spec build_payloads(map(), [resolved_input()], keyword()) ::
          {:ok, [map()]} | {:error, [String.t()]}
  def build_payloads(base_payload, resolved_inputs, opts \\ [])

  def build_payloads(base_payload, resolved_inputs, opts)
      when is_map(base_payload) and is_list(resolved_inputs) do
    resolved_inputs
    |> Enum.reduce_while({:ok, []}, fn resolved_input, {:ok, acc} ->
      case build_input_payloads(base_payload, resolved_input, opts) do
        {:ok, []} -> {:cont, {:ok, acc}}
        {:ok, payloads} -> {:cont, {:ok, acc ++ payloads}}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
  end

  def build_payloads(_base_payload, _resolved_inputs, _opts) do
    {:error, ["base payload must be an object and resolved inputs must be a list"]}
  end

  @spec normalize_rows(String.t() | atom(), [map()]) :: [map()]
  def normalize_rows(entity, rows) when is_list(rows) do
    entity = normalize_entity(entity)

    rows
    |> Enum.map(&normalize_row(entity, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&item_identity/1)
  end

  def normalize_rows(_entity, _rows), do: []

  defp build_input_payloads(base_payload, resolved_input, opts) do
    with {:ok, descriptor, rows} <- extract_input_descriptor(resolved_input) do
      items = normalize_rows(descriptor.entity, rows)

      case items do
        [] ->
          {:ok, []}

        _ ->
          PluginInputs.chunk_single_input_payloads(
            base_payload,
            %{
              "name" => descriptor.name,
              "entity" => descriptor.entity,
              "query" => descriptor.query
            },
            items,
            opts
          )
      end
    end
  end

  defp extract_input_descriptor(input) when is_map(input) do
    name = string_value(input, [:name, "name"])
    entity = string_value(input, [:entity, "entity"])
    query = string_value(input, [:query, "query"])
    rows = list_value(input, [:rows, "rows"])

    cond do
      blank?(name) -> {:error, ["resolved input is missing name"]}
      blank?(entity) -> {:error, ["resolved input is missing entity"]}
      blank?(query) -> {:error, ["resolved input is missing query"]}
      is_nil(rows) -> {:error, ["resolved input is missing rows"]}
      true -> {:ok, %{name: name, entity: normalize_entity(entity), query: query}, rows}
    end
  end

  defp extract_input_descriptor(_), do: {:error, ["resolved input must be an object"]}

  defp normalize_row(entity, row) when is_map(row) do
    case entity do
      "devices" -> normalize_device_row(row)
      "interfaces" -> normalize_interface_row(row)
      _ -> normalize_generic_row(row)
    end
  end

  defp normalize_row(_entity, _row), do: nil

  defp normalize_device_row(row) do
    uid = string_value(row, [:uid, "uid", :device_uid, "device_uid", :id, "id"])

    if blank?(uid) do
      nil
    else
      compact_map(%{
        "uid" => uid,
        "ip" => string_value(row, [:ip, "ip", :device_ip, "device_ip"]),
        "hostname" => string_value(row, [:hostname, "hostname", :name, "name"]),
        "vendor" => string_value(row, [:vendor, "vendor", :vendor_name, "vendor_name"]),
        "model" => string_value(row, [:model, "model"]),
        "site" => string_value(row, [:site, "site", :region, "region"]),
        "zone" => string_value(row, [:zone, "zone"]),
        "labels" => map_value(row, [:labels, "labels", :tags, "tags"])
      })
    end
  end

  defp normalize_interface_row(row) do
    id =
      string_value(row, [
        :id,
        "id",
        :interface_uid,
        "interface_uid",
        :if_uid,
        "if_uid"
      ])

    if blank?(id) do
      nil
    else
      compact_map(%{
        "id" => id,
        "uid" => id,
        "device_uid" => string_value(row, [:device_uid, "device_uid", :device_id, "device_id"]),
        "device_ip" => string_value(row, [:device_ip, "device_ip", :ip, "ip"]),
        "if_index" => integer_value(row, [:if_index, "if_index"]),
        "if_name" => string_value(row, [:if_name, "if_name", :name, "name"]),
        "if_descr" => string_value(row, [:if_descr, "if_descr"]),
        "if_alias" => string_value(row, [:if_alias, "if_alias"]),
        "if_type" => integer_value(row, [:if_type, "if_type"]),
        "if_type_name" => string_value(row, [:if_type_name, "if_type_name"]),
        "ip_addresses" => list_value(row, [:ip_addresses, "ip_addresses"]),
        "labels" => map_value(row, [:labels, "labels", :tags, "tags"])
      })
    end
  end

  defp normalize_generic_row(row) do
    row
    |> stringify_keys()
    |> compact_map()
    |> then(fn normalized ->
      if map_size(normalized) == 0, do: nil, else: normalized
    end)
  end

  defp item_identity(item) do
    cond do
      is_binary(item["uid"]) and item["uid"] != "" -> "uid:" <> item["uid"]
      is_binary(item["id"]) and item["id"] != "" -> "id:" <> item["id"]
      true -> Jason.encode!(item)
    end
  end

  defp normalize_entity(entity) when is_atom(entity),
    do: entity |> Atom.to_string() |> normalize_entity()

  defp normalize_entity(entity) when is_binary(entity) do
    entity
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_entity(_), do: ""

  defp stringify_keys(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_keys(value)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp compact_map(%{} = map) do
    map
    |> Enum.reject(fn {_key, value} -> nil_or_empty?(value) end)
    |> Map.new()
  end

  defp string_value(map, keys) do
    case raw_value(map, keys) do
      nil ->
        nil

      value when is_binary(value) ->
        String.trim(value)

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        :erlang.float_to_binary(value)

      _ ->
        nil
    end
  end

  defp integer_value(map, keys) do
    case raw_value(map, keys) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp map_value(map, keys) do
    case raw_value(map, keys) do
      value when is_map(value) -> stringify_keys(value)
      _ -> nil
    end
  end

  defp list_value(map, keys) do
    case raw_value(map, keys) do
      value when is_list(value) -> value
      _ -> nil
    end
  end

  defp raw_value(map, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key)
    end)
  end

  defp nil_or_empty?(nil), do: true
  defp nil_or_empty?(""), do: true
  defp nil_or_empty?([]), do: true
  defp nil_or_empty?(%{} = value), do: map_size(value) == 0
  defp nil_or_empty?(_), do: false

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true
end
