defmodule ServiceRadar.Edge.ContractRegistryEpochDocumentTest do
  @moduledoc """
  The registry epoch signature: its preimage bytes, a pinned signature vector, and every signed
  field failing verification when it is changed after signing.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ContractRegistryEpochDocument, as: EpochDocument
  alias ServiceRadar.Edge.ContractRegistryGrammar
  alias ServiceRadar.Edge.IssuerKey

  @key IssuerKey.from_seed(:binary.copy(<<0x24>>, 32))
  @bundle :binary.copy(<<0xAB>>, 32)

  @entry %{
    contract_id: "example.contract",
    contract_version: 2,
    contract_bundle_sha256: @bundle,
    route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
    traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
    partition_rule: :network_scope_v1,
    cost_model_version: 3,
    projection_revision: 5
  }

  defp keys, do: %{@key.key_id => @key.public_key}

  defp frame(s) when is_binary(s), do: <<byte_size(s)::big-64, s::binary>>
  defp u64(v), do: <<v::big-64>>

  test "the signing preimage frames the epoch, the snapshot and each signed entry field" do
    snapshot = :binary.copy(<<0xCD>>, 32)

    expected =
      IO.iodata_to_binary([
        frame("serviceradar.edge.contract_registry_epoch.v1"),
        u64(1),
        u64(1_000_007),
        frame(snapshot),
        u64(1),
        frame("example.contract"),
        u64(2),
        frame(@bundle),
        frame("EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1"),
        frame("EDGE_RECORD_TRAFFIC_CLASS_BULK"),
        frame("network_scope_v1"),
        u64(3),
        u64(5)
      ])

    assert ContractRegistryGrammar.registry_epoch_signing_bytes(%{
             epoch: 1_000_007,
             snapshot_sha256: snapshot,
             contracts: [@entry]
           }) == expected
  end

  test "an epoch signs deterministically under the pinned vector and verifies" do
    signed = EpochDocument.sign(1_000_007, [@entry], @key)

    snapshot_preimage = [
      frame("serviceradar.edge.contract_registry.v1"),
      u64(1),
      u64(1),
      frame("example.contract"),
      u64(2),
      frame(@bundle)
    ]

    assert signed.snapshot_sha256 == :crypto.hash(:sha256, snapshot_preimage)

    assert Base.encode16(signed.signature, case: :lower) ==
             "5030a33ea82279faef07f59a220d0d8c46b29dcc412db78aa0fb014bfe71e6fa" <>
               "31350bcd173af5667babc2a0b941b57756040c4ee5e0f43c5984e8f247bf190f"

    assert signed.signing_key_id == @key.key_id
    assert :ok == EpochDocument.verify(signed, keys())
  end

  test "changing any signed field after signing fails verification" do
    signed = EpochDocument.sign(1_000_007, [@entry], @key)
    ref = {"example.contract", 2}

    tampered = [
      epoch: %{signed | epoch: 1_000_008},
      bundle: put_in(signed.contracts[ref].contract_bundle_sha256, :binary.copy(<<0xEE>>, 32)),
      traffic_class:
        put_in(signed.contracts[ref].traffic_class, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE),
      cost_model_version: put_in(signed.contracts[ref].cost_model_version, 4),
      projection_revision: put_in(signed.contracts[ref].projection_revision, 6),
      snapshot: %{signed | snapshot_sha256: :binary.copy(<<0x00>>, 32)}
    ]

    for {field, epoch} <- tampered do
      assert {:error, :registry_epoch_signature_invalid} == EpochDocument.verify(epoch, keys()),
             "a changed #{field} still verified"
    end
  end

  test "an epoch signed by a key the verifier does not hold is refused" do
    signed = EpochDocument.sign(1_000_007, [@entry], @key)
    other = IssuerKey.from_seed(:binary.copy(<<0x25>>, 32))

    assert {:error, :registry_epoch_signing_key_unknown} ==
             EpochDocument.verify(signed, %{other.key_id => other.public_key})
  end

  test "a trust-document epoch parses back to the epoch that was signed" do
    signed = EpochDocument.sign(1_000_007, [@entry], @key)
    trust = signed |> Map.put(:state, :draining) |> EpochDocument.to_trust() |> json_round_trip()

    assert {:ok, parsed} = EpochDocument.from_trust(trust)
    assert parsed.state == :draining
    assert :ok == EpochDocument.verify(parsed, keys())

    assert {:error, :keys} = EpochDocument.from_trust(Map.put(trust, "extra", 1))

    duplicate = Map.update!(trust, "contracts", &(&1 ++ &1))
    assert {:error, :duplicate_contract} = EpochDocument.from_trust(duplicate)
  end

  defp json_round_trip(term), do: term |> Jason.encode!() |> Jason.decode!()
end
