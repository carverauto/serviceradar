defmodule ServiceRadar.Edge.ContractRegistryGrammar do
  @moduledoc """
  The digest and signing preimages of the core-derived contract registry, in the framing of
  `ServiceRadar.Edge.HashGrammar`: big-endian u64, u64 length-framed strings and bytes, and
  1-byte presence markers. Each preimage leads with its own domain tag and format version, so a
  digest of one object can never collide with another's.

  These digests are computed only in Elixir. The agent never computes them; it copies the
  contract reference from its signed capability. The gateway rebuilds only the epoch signing
  preimage, from the trust document's registry member.

    * `payload_schema_fingerprint/1`: a payload message definition, walked transitively.
    * `contract_bundle_digest/1`: one catalog entry (`contract_bundle_sha256`).
    * `contract_registry_snapshot_digest/1`: the set of bundles (`registry_snapshot_sha256`).
    * `registry_epoch_signing_bytes/1`: what the issuer key signs for one registry epoch.

  None of them covers an epoch number or a lifecycle state except the epoch preimage, which
  covers the epoch number. Every replica of a release therefore derives the same snapshot digest.
  """

  @schema_domain "serviceradar.edge.payload_schema.v1"
  @bundle_domain "serviceradar.edge.contract_bundle.v1"
  @snapshot_domain "serviceradar.edge.contract_registry.v1"
  @epoch_domain "serviceradar.edge.contract_registry_epoch.v1"
  @format_version 1

  @type schema_field :: %{
          number: pos_integer(),
          name: String.t(),
          type: String.t(),
          label: String.t(),
          type_name: String.t() | nil
        }

  @type bundle :: %{
          contract_id: String.t(),
          contract_version: pos_integer(),
          authority: atom(),
          package_id: String.t() | nil,
          route_profile: atom(),
          traffic_class: atom(),
          partition_rule: atom(),
          cost_model_version: pos_integer(),
          max_projected_rows: pos_integer(),
          write_bytes_per_row: pos_integer(),
          max_projected_write_bytes: pos_integer() | nil,
          payload_message: String.t(),
          payload_schema_sha256: <<_::256>>,
          projection_revision: pos_integer()
        }

  @type epoch_entry :: %{
          contract_id: String.t(),
          contract_version: pos_integer(),
          contract_bundle_sha256: <<_::256>>,
          route_profile: atom(),
          traffic_class: atom(),
          partition_rule: atom(),
          cost_model_version: pos_integer(),
          projection_revision: pos_integer()
        }

  @doc """
  SHA-256 over a payload message definition: each message reached from the payload, in
  first-visit order, with its fields in field-number order. A field contributes its number,
  name, type, label and, for a message or enum field, the referenced type's full name. Comments
  and source formatting are not part of a definition, so they cannot move the fingerprint.
  """
  @spec payload_schema_fingerprint([{String.t(), [schema_field()]}]) :: <<_::256>>
  def payload_schema_fingerprint(messages) when is_list(messages) do
    sha256([
      str(@schema_domain),
      u64(@format_version),
      u64(length(messages)),
      Enum.map(messages, fn {name, fields} ->
        [str(name), u64(length(fields)), Enum.map(fields, &schema_field/1)]
      end)
    ])
  end

  @doc """
  The bundle digest of one contract. `max_projected_write_bytes` is presence-marked: only a
  contract with a projected write ceiling of its own carries it.
  """
  @spec contract_bundle_digest(bundle()) :: <<_::256>>
  def contract_bundle_digest(b) do
    sha256([
      str(@bundle_domain),
      u64(@format_version),
      str(b.contract_id),
      u64(b.contract_version),
      str(Atom.to_string(b.authority)),
      optional_str(b.package_id),
      str(Atom.to_string(b.route_profile)),
      str(Atom.to_string(b.traffic_class)),
      str(Atom.to_string(b.partition_rule)),
      u64(b.cost_model_version),
      u64(b.max_projected_rows),
      u64(b.write_bytes_per_row),
      optional_u64(b.max_projected_write_bytes),
      str(b.payload_message),
      bytes(b.payload_schema_sha256),
      u64(b.projection_revision)
    ])
  end

  @doc "The snapshot digest of a set of `{contract_id, contract_version, bundle_sha256}`."
  @spec contract_registry_snapshot_digest([{String.t(), pos_integer(), <<_::256>>}]) ::
          <<_::256>>
  def contract_registry_snapshot_digest(triples) when is_list(triples) do
    sorted = Enum.sort_by(triples, fn {id, version, _digest} -> {id, version} end)

    sha256([
      str(@snapshot_domain),
      u64(@format_version),
      u64(length(sorted)),
      Enum.map(sorted, fn {id, version, digest} -> [str(id), u64(version), bytes(digest)] end)
    ])
  end

  @doc """
  The bytes the issuer key signs for a registry epoch: the epoch number, the snapshot digest and,
  per contract sorted by `(contract_id, contract_version)`, its bundle digest, the admission
  fields the gateway routes and charges from, and its `projection_revision`.
  """
  @spec registry_epoch_signing_bytes(%{
          epoch: pos_integer(),
          snapshot_sha256: <<_::256>>,
          contracts: [epoch_entry()]
        }) :: binary()
  def registry_epoch_signing_bytes(%{epoch: epoch, snapshot_sha256: snapshot, contracts: entries})
      when is_list(entries) do
    sorted = Enum.sort_by(entries, &{&1.contract_id, &1.contract_version})

    IO.iodata_to_binary([
      str(@epoch_domain),
      u64(@format_version),
      u64(epoch),
      bytes(snapshot),
      u64(length(sorted)),
      Enum.map(sorted, &epoch_entry/1)
    ])
  end

  defp epoch_entry(e) do
    [
      str(e.contract_id),
      u64(e.contract_version),
      bytes(e.contract_bundle_sha256),
      str(Atom.to_string(e.route_profile)),
      str(Atom.to_string(e.traffic_class)),
      str(Atom.to_string(e.partition_rule)),
      u64(e.cost_model_version),
      u64(e.projection_revision)
    ]
  end

  defp schema_field(f) do
    [u64(f.number), str(f.name), str(f.type), str(f.label), optional_str(f.type_name)]
  end

  defp sha256(io), do: :crypto.hash(:sha256, io)

  @u64_max 0xFFFFFFFFFFFFFFFF

  defp u64(v) when is_integer(v) and v >= 0 and v <= @u64_max, do: <<v::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]
  defp str(s) when is_binary(s), do: bytes(s)
  defp optional_str(nil), do: <<0>>
  defp optional_str(s) when is_binary(s), do: [<<1>>, str(s)]
  defp optional_u64(nil), do: <<0>>
  defp optional_u64(v), do: [<<1>>, u64(v)]
end
