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

  @spec normalize_rows(String.t() | atom(), [map()], [String.t()]) :: [map()]
  def normalize_rows(entity, rows, fields \\ [])

  def normalize_rows(entity, rows, fields) when is_list(rows) do
    entity = ValueUtils.normalize_entity(entity)

    rows
    |> Enum.map(&normalize_row(entity, &1, fields))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&IdentityUtils.item_identity/1)
  end

  def normalize_rows(_entity, _rows, _fields), do: []

  defp build_input_payloads(base_payload, resolved_input, opts) do
    with {:ok, descriptor, rows} <- extract_input_descriptor(resolved_input) do
      items = normalize_rows(descriptor.entity, rows, Map.get(descriptor, :fields, []))

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
        descriptor = %{name: name, entity: ValueUtils.normalize_entity(entity), query: query}

        case ValueUtils.list_value(input, [:fields, "fields"]) do
          fields when is_list(fields) and fields != [] ->
            {:ok, Map.put(descriptor, :fields, fields), rows}

          _ ->
            {:ok, descriptor, rows}
        end
    end
  end

  defp extract_input_descriptor(_), do: {:error, ["resolved input must be an object"]}

  defp normalize_row(entity, row, fields) when is_map(row) do
    case entity do
      "devices" -> row |> normalize_device_row() |> project_fields(row, fields)
      "interfaces" -> normalize_interface_row(row)
      _ -> normalize_generic_row(row)
    end
  end

  defp normalize_row(_entity, _row, _fields), do: nil

  # Operator-selected fields (validated by SRQLInputResolver.input_fields/2),
  # copied under "fields" so they never shadow the fixed item keys above.
  defp project_fields(nil, _row, _fields), do: nil
  defp project_fields(item, _row, []), do: item

  defp project_fields(item, row, fields) do
    metadata = ValueUtils.map_value(row, [:metadata, "metadata"], stringify_keys: true) || %{}

    projected =
      fields
      |> Enum.map(fn field -> {field, projected_value(row, metadata, field)} end)
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Map.new()

    if projected == %{}, do: item, else: Map.put(item, "fields", projected)
  end

  defp projected_value(_row, metadata, "metadata." <> key), do: Map.get(metadata, key)

  defp projected_value(row, _metadata, field) do
    case Map.fetch(row, field) do
      {:ok, value} -> value
      :error -> row |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Map.get(field)
    end
  end

  defp normalize_device_row(row) do
    uid = ValueUtils.string_value(row, [:uid, "uid", :device_uid, "device_uid", :id, "id"])
    metadata = ValueUtils.map_value(row, [:metadata, "metadata"], stringify_keys: true) || %{}

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
          ValueUtils.map_value(row, [:labels, "labels", :tags, "tags"], stringify_keys: true),
        # Safe source/ownership evidence used by trusted host-authority
        # generation. Preserve only an explicit finite set; arbitrary device
        # metadata can contain unrelated or sensitive integration data.
        "integration_id" =>
          device_string(row, metadata, [:integration_id, "integration_id"], ["integration_id"]),
        "provider_ref" =>
          device_string(
            row,
            metadata,
            [:provider_ref, "provider_ref"],
            ["hypervisor_provider_ref", "provider_ref"]
          ),
        "node" => device_string(row, metadata, [:node, "node"], ["node", "proxmox_node"]),
        "cluster" =>
          device_string(
            row,
            metadata,
            [:cluster, "cluster"],
            ["cluster", "proxmox_cluster"]
          ),
        "vmid" => device_string(row, metadata, [:vmid, "vmid"], ["hypervisor_vmid", "vmid"]),
        "target_kind" => device_target_kind(row, metadata),
        "device_role" =>
          device_string(row, metadata, [:device_role, "device_role"], ["device_role"]),
        "proxmox_base_url" =>
          device_string(
            row,
            metadata,
            [:proxmox_base_url, "proxmox_base_url"],
            ["proxmox_base_url"]
          )
      })
    end
  end

  defp device_string(row, metadata, row_keys, metadata_keys) do
    ValueUtils.string_value(row, row_keys) || ValueUtils.string_value(metadata, metadata_keys)
  end

  defp device_target_kind(row, metadata) do
    explicit =
      device_string(row, metadata, [:target_kind, "target_kind"], ["target_kind"])

    guest_type = ValueUtils.string_value(metadata, ["hypervisor_guest_type", "guest_type"])
    device_role = ValueUtils.string_value(metadata, ["device_role"])

    cond do
      explicit not in [nil, ""] -> explicit
      guest_type in ["lxc", "container"] -> "lxc_guest"
      guest_type in ["qemu", "vm"] -> "qemu_guest"
      device_role == "hypervisor" -> "pve_host"
      true -> nil
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
