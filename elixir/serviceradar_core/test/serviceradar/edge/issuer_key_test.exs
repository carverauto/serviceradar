defmodule ServiceRadar.Edge.IssuerKeyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.IssuerKey
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1

  @seed :binary.copy(<<0x5A>>, 32)
  @other_seed :binary.copy(<<0x3C>>, 32)

  test "a seed makes the same key, and the key id is the first 16 bytes of the domain hash" do
    key = IssuerKey.from_seed(@seed)

    <<key_id::binary-size(16), _::binary>> =
      :crypto.hash(:sha256, ["serviceradar.edge.issuer_key.v1", key.public_key])

    assert key == IssuerKey.from_seed(@seed)
    assert key.issuer_id == "serviceradar-core"
    assert key.key_id == key_id
    assert byte_size(key.public_key) == 32
    refute key.key_id == IssuerKey.from_seed(@other_seed).key_id
  end

  test "a signed capability passes the capability validator and verifies only under its own key" do
    key = IssuerKey.from_seed(@seed)
    signed = IssuerKey.sign(capability(), key)

    assert :ok == CapabilitySigning.validate(signed, :source)
    assert %{capability_version: 1, algorithm: "ed25519"} = signed
    assert signed.issuer_id == key.issuer_id
    assert signed.issuer_key_id == key.key_id
    assert CapabilitySigning.verify(signed, :source, key.public_key)
    refute CapabilitySigning.verify(signed, :source, IssuerKey.from_seed(@other_seed).public_key)

    tampered = %{signed | expires_at_unix_nano: signed.expires_at_unix_nano + 1}
    refute CapabilitySigning.verify(tampered, :source, key.public_key)
  end

  test "the trust entry carries the public key and never the seed" do
    key = IssuerKey.from_seed(@seed)
    entry = IssuerKey.trust_entry(key)

    assert Base.decode64!(entry["public_key"]) == key.public_key
    assert Base.decode64!(entry["issuer_key_id"]) == key.key_id
    assert Base.decode64!(entry["issuer_id"]) == key.issuer_id
    assert entry["purposes"] == ["production", "source", "delivery"]
    refute inspect(entry) =~ Base.encode64(@seed)
    refute Map.has_key?(entry, "seed")
    refute inspect(key) =~ "seed"
    refute inspect(key) =~ Base.encode64(@seed)
  end

  defp capability do
    %EdgeSignedCapabilityV1{
      not_before_unix_nano: 1_000,
      expires_at_unix_nano: 2_000,
      claims:
        {:source,
         %EdgeSourceClaimsV1{
           kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
           context_id: Ecto.UUID.bingenerate(),
           scope_id: Ecto.UUID.bingenerate(),
           scope_sha256: :crypto.hash(:sha256, "range"),
           collection_not_before_unix_nano: 1_000,
           collection_expires_unix_nano: 2_000
         }}
    }
  end
end
