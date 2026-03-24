defmodule ServiceRadar.Plugins.PluginInputPayloadBuilder do
  @moduledoc """
  Builds `serviceradar.plugin_inputs.v1` payloads from resolved SRQL input rows.

  This is the first-class control-plane path for converting server-side query
  results (devices, interfaces, and future entities) into bounded assignment
  payloads for plugins.
  """

  alias ServiceRadar.Plugins.IdentityUtils
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.PluginInputs
  alias ServiceRadar.Plugins.ValueUtils

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
    Enum.reduce_while(resolved_inputs, {:ok, []}, fn resolved_input, {:ok, acc} ->
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
    entity = ValueUtils.normalize_entity(entity)

    rows
    |> Enum.map(&normalize_row(entity, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&IdentityUtils.item_identity/1)
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
            chunk_input_descriptor(descriptor),
            items,
            opts
          )
      end
    end
  end

  @spec chunk_input_descriptor(%{name: String.t(), entity: String.t(), query: String.t()}) ::
          PluginInputs.input_descriptor()
  defp chunk_input_descriptor(descriptor) do
    %{
      name: descriptor.name,
      entity: descriptor.entity,
      query: descriptor.query
    }
  end

  defp extract_input_descriptor(input) when is_map(input) do
    name = ValueUtils.string_value(input, [:name, "name"])
    entity = ValueUtils.string_value(input, [:entity, "entity"])
    query = ValueUtils.string_value(input, [:query, "query"])
    rows = ValueUtils.list_value(input, [:rows, "rows"])

    cond do
      ValueUtils.blank_string?(name) ->
        {:error, ["resolved input is missing name"]}

      ValueUtils.blank_string?(entity) ->
        {:error, ["resolved input is missing entity"]}

      ValueUtils.blank_string?(query) ->
        {:error, ["resolved input is missing query"]}

      is_nil(rows) ->
        {:error, ["resolved input is missing rows"]}

      true ->
        {:ok, %{name: name, entity: ValueUtils.normalize_entity(entity), query: query}, rows}
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
    uid = ValueUtils.string_value(row, [:uid, "uid", :device_uid, "device_uid", :id, "id"])

    if ValueUtils.blank_string?(uid) do
      nil
    else
      compact_map(%{
        "uid" => uid,
        "ip" => ValueUtils.string_value(row, [:ip, "ip", :device_ip, "device_ip"]),
        "hostname" => ValueUtils.string_value(row, [:hostname, "hostname", :name, "name"]),
        "vendor" =>
          ValueUtils.string_value(row, [:vendor, "vendor", :vendor_name, "vendor_name"]),
        "model" => ValueUtils.string_value(row, [:model, "model"]),
        "site" => ValueUtils.string_value(row, [:site, "site", :region, "region"]),
        "zone" => ValueUtils.string_value(row, [:zone, "zone"]),
        "labels" =>
          ValueUtils.map_value(row, [:labels, "labels", :tags, "tags"], stringify_keys: true)
      })
    end
  end

  defp normalize_interface_row(row) do
    id =
      ValueUtils.string_value(row, [
        :id,
        "id",
        :interface_uid,
        "interface_uid",
        :if_uid,
        "if_uid"
      ])

    if ValueUtils.blank_string?(id) do
      nil
    else
      compact_map(%{
        "id" => id,
        "uid" => id,
        "device_uid" =>
          ValueUtils.string_value(row, [:device_uid, "device_uid", :device_id, "device_id"]),
        "device_ip" => ValueUtils.string_value(row, [:device_ip, "device_ip", :ip, "ip"]),
        "if_index" => ValueUtils.int_value(row, [:if_index, "if_index"]),
        "if_name" => ValueUtils.string_value(row, [:if_name, "if_name", :name, "name"]),
        "if_descr" => ValueUtils.string_value(row, [:if_descr, "if_descr"]),
        "if_alias" => ValueUtils.string_value(row, [:if_alias, "if_alias"]),
        "if_type" => ValueUtils.int_value(row, [:if_type, "if_type"]),
        "if_type_name" => ValueUtils.string_value(row, [:if_type_name, "if_type_name"]),
        "ip_addresses" => ValueUtils.list_value(row, [:ip_addresses, "ip_addresses"]),
        "labels" =>
          ValueUtils.map_value(row, [:labels, "labels", :tags, "tags"], stringify_keys: true)
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

  defp stringify_keys(value), do: MapUtils.stringify_keys(value)

  defp compact_map(%{} = map) do
    map
    |> Enum.reject(fn {_key, value} -> nil_or_empty?(value) end)
    |> Map.new()
  end

  defp nil_or_empty?(nil), do: true
  defp nil_or_empty?(""), do: true
  defp nil_or_empty?([]), do: true
  defp nil_or_empty?(%{} = value), do: map_size(value) == 0
  defp nil_or_empty?(_), do: false
end
