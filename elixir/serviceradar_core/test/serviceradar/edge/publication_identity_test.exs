defmodule ServiceRadar.Edge.PublicationIdentityTest do
  @moduledoc """
  Task 1.5-j: the three RELATION scenarios of the requirement "Broker publication identity is
  separate from the semantic envelope", this runtime's half. The Go peer is
  `TestPublicationIdentityIsSeparateFromTheSemanticEnvelope`.

  ## Why this is not the golden test

  `edge_v1_golden_test.exs` already holds these grammars to the SAME committed preimage and
  header fixtures the Go runtime is held to, which is what makes the two implementations
  byte-identical. That pins the GRAMMAR. It does not pin what the grammar is FOR: that these are
  SEPARATE identities -- from the semantic envelope, and from each other. That is a claim about
  how the values relate as inputs CHANGE, and a frozen fixture has no changing input.

  The distinction is measurable, not stylistic. Drop the semantic-envelope commitment from the
  msg-id transcript and regenerate the fixtures against the change, and every golden assertion
  goes green again -- the fixture now agrees with the mutant. The relation assertions here do not,
  because nothing about them was regenerated. Measured on the Go side, then again on this one.

  So NO COMMITTED VALUE IS READ HERE. Every input is built in this file and every assertion is
  between two computed results.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ServiceRadar.Edge.PublicationIdentity

  # A structurally valid UUIDv7: the validated encoders check UUID SEMANTICS, not 16-byte shape.
  defp uuidv7(seed) do
    bytes = Enum.map(0..15, &rem(seed + &1, 256))

    bytes
    |> List.replace_at(6, bor(band(Enum.at(bytes, 6), 0x0F), 0x70))
    |> List.replace_at(8, bor(band(Enum.at(bytes, 8), 0x3F), 0x80))
    |> :erlang.list_to_binary()
  end

  defp fixture do
    slot = %{
      network_scope_id: uuidv7(0x40),
      authenticated_agent_id: "agent-0",
      spool_id: uuidv7(0x01),
      sequence: 7
    }

    {slot, :binary.copy(<<0xAA>>, 32), :binary.copy(<<0xBB>>, 32)}
  end

  test "a re-encoded record changes its message id but not its delivery id" do
    {slot, sed, record_sha} = fixture()

    assert {:ok, msg_id} = PublicationIdentity.nats_msg_id(slot, sed, record_sha)
    assert {:ok, delivery_id} = PublicationIdentity.delivery_id(slot)

    re_encoded = :binary.copy(<<0xCC>>, 32)
    assert {:ok, other} = PublicationIdentity.nats_msg_id(slot, sed, re_encoded)

    refute other == msg_id,
           "msg-id must depend on record_sha256, or a broker dedupes two encodings as one"

    # delivery_id/1 takes the slot ALONE -- there is no record digest to hand it -- so its
    # stability across a re-encode is structural rather than measured. Asserting it pins the
    # SIGNATURE: giving the delivery id a digest input would have to change this call site.
    assert {:ok, ^delivery_id} = PublicationIdentity.delivery_id(slot)
  end

  test "the message id commits the semantic envelope without becoming it" do
    {slot, sed, record_sha} = fixture()

    assert {:ok, msg_id} = PublicationIdentity.nats_msg_id(slot, sed, record_sha)

    other_sed = :binary.copy(<<0xDD>>, 32)
    assert {:ok, other} = PublicationIdentity.nats_msg_id(slot, other_sed, record_sha)

    refute other == msg_id, "msg-id must depend on semantic_envelope_sha256"

    refute msg_id == Base.url_encode64(sed, padding: false),
           "msg-id is the semantic envelope digest re-encoded, not a separate identity"

    assert {:ok, raw} = Base.url_decode64(msg_id, padding: false)
    refute raw == sed, "msg-id decodes to the semantic envelope digest"
  end

  test "edge and service publication values cannot collide" do
    {slot, sed, record_sha} = fixture()

    assert {:ok, msg_id} = PublicationIdentity.nats_msg_id(slot, sed, record_sha)
    assert {:ok, delivery_id} = PublicationIdentity.delivery_id(slot)

    # The service transcripts mirror the edge FIELD ORDER exactly, so a service slot carrying the
    # same values leaves the domain tag as the only difference between the two preimages -- which
    # is the whole claim. A twin whose lane id and spool id merely happened to differ would prove
    # separation by accident.
    twin = %{
      network_scope_id: slot.network_scope_id,
      authenticated_service_id: slot.authenticated_agent_id,
      publication_lane_id: slot.spool_id,
      publication_sequence: slot.sequence
    }

    assert {:ok, service_msg_id} = PublicationIdentity.service_nats_msg_id(twin, sed, record_sha)
    assert {:ok, service_delivery_id} = PublicationIdentity.service_delivery_id(twin)

    refute service_msg_id == msg_id, "edge and service msg-id must differ on the domain tag alone"

    refute service_delivery_id == delivery_id,
           "edge and service delivery-id must differ on the domain tag alone"
  end
end
