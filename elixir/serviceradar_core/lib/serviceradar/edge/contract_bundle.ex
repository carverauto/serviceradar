defmodule ServiceRadar.Edge.ContractBundle do
  @moduledoc """
  Derives the contract registry of this release from `ServiceRadar.Edge.ContractCatalog`.

  Each catalog entry becomes a registry entry whose `contract_bundle_sha256` is a pure function
  of the entry and of its payload message definition, and the set of entries has one
  `registry_snapshot_sha256` (`ServiceRadar.Edge.ContractRegistryGrammar`). Two installs, and
  every replica of one install, running the same release therefore derive the same digests.

  The payload schema fingerprint walks the generated protobuf modules' message definitions
  (`__message_props__/0`), never `.proto` source, so comments and formatting do not move it.
  """

  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.ContractRegistryGrammar

  @type registry_entry :: ContractRegistryGrammar.epoch_entry()

  @type local :: %{
          snapshot_sha256: <<_::256>>,
          contracts: %{ContractCatalog.ref() => registry_entry()}
        }

  @cache_key {__MODULE__, :local}

  @doc """
  This release's registry: every catalog entry with its bundle digest, and the snapshot digest.
  It depends only on compiled code, so it is computed once per node.
  """
  @spec local() :: local()
  def local do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        local = derive(ContractCatalog.entries())
        :persistent_term.put(@cache_key, local)
        local

      local ->
        local
    end
  end

  @doc "The registry derived from a list of catalog entries."
  @spec derive([ContractCatalog.entry()]) :: local()
  def derive(entries) do
    contracts = Map.new(entries, &{&1.ref, registry_entry(&1)})
    %{snapshot_sha256: snapshot_sha256(Map.values(contracts)), contracts: contracts}
  end

  @doc "The snapshot digest of a set of registry entries."
  @spec snapshot_sha256([registry_entry()]) :: <<_::256>>
  def snapshot_sha256(entries) do
    entries
    |> Enum.map(&{&1.contract_id, &1.contract_version, &1.contract_bundle_sha256})
    |> ContractRegistryGrammar.contract_registry_snapshot_digest()
  end

  @doc "The registry entry of one catalog entry, with its bundle digest."
  @spec registry_entry(ContractCatalog.entry()) :: registry_entry()
  def registry_entry(%{ref: {id, version}} = entry) do
    %{
      contract_id: id,
      contract_version: version,
      contract_bundle_sha256: bundle_sha256(entry),
      route_profile: entry.route_profile,
      traffic_class: entry.traffic_class,
      partition_rule: entry.partition_rule,
      cost_model_version: entry.cost_model_version,
      projection_revision: entry.projection_revision
    }
  end

  @doc "The bundle digest of one catalog entry."
  @spec bundle_sha256(ContractCatalog.entry()) :: <<_::256>>
  def bundle_sha256(%{ref: {id, version}} = entry) do
    ContractRegistryGrammar.contract_bundle_digest(%{
      contract_id: id,
      contract_version: version,
      authority: entry.authority,
      package_id: Map.get(entry, :package_id),
      route_profile: entry.route_profile,
      traffic_class: entry.traffic_class,
      partition_rule: entry.partition_rule,
      cost_model_version: entry.cost_model_version,
      max_projected_rows: entry.max_projected_rows,
      write_bytes_per_row: entry.write_bytes_per_row,
      max_projected_write_bytes: Map.get(entry, :max_projected_write_bytes),
      payload_message: entry.payload.full_name(),
      payload_schema_sha256: schema_fingerprint(entry.payload),
      projection_revision: entry.projection_revision
    })
  end

  @doc """
  The schema fingerprint of a generated protobuf message module: the message and every message
  it reaches through a field, each visited once, fields in field-number order.
  """
  @spec schema_fingerprint(module()) :: <<_::256>>
  def schema_fingerprint(message) when is_atom(message) do
    {messages, _seen} = visit(message, {[], MapSet.new()})
    ContractRegistryGrammar.payload_schema_fingerprint(Enum.reverse(messages))
  end

  defp visit(message, {acc, seen} = state) do
    name = message.full_name()

    if MapSet.member?(seen, name) do
      state
    else
      props = message.__message_props__()
      fields = props.field_props |> Map.values() |> Enum.sort_by(& &1.fnum)
      state = {[{name, Enum.map(fields, &field(&1, props.syntax))} | acc], MapSet.put(seen, name)}

      fields
      |> Enum.filter(& &1.embedded?)
      |> Enum.reduce(state, fn field, state -> visit(field.type, state) end)
    end
  end

  defp field(props, syntax) do
    {type, type_name} = field_type(props)

    %{
      number: props.fnum,
      name: props.name,
      type: type,
      label: label(props, syntax),
      type_name: type_name
    }
  end

  defp field_type(%{embedded?: true, type: message}), do: {"message", message.full_name()}
  defp field_type(%{type: {:enum, enum}}), do: {"enum", enum.full_name()}
  defp field_type(%{type: scalar}) when is_atom(scalar), do: {Atom.to_string(scalar), nil}

  defp label(%{repeated?: true}, _syntax), do: "repeated"
  defp label(%{map?: true}, _syntax), do: "repeated"
  defp label(%{required?: true}, _syntax), do: "required"
  defp label(%{proto3_optional?: true}, _syntax), do: "optional"
  defp label(%{optional?: true}, :proto2), do: "optional"
  defp label(_props, _syntax), do: "singular"
end
