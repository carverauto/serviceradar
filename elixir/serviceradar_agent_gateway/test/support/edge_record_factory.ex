defmodule ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory do
  @moduledoc false

  # Builds structurally valid, Ed25519-signed SYNTHETIC edge records, delivery frames, delivery
  # capabilities and trust documents. Every identifier is generated here; nothing is captured from
  # a running system. The record is sealed (semantic digest) LAST, so it covers the capabilities it
  # ships with, and `:mutate` runs just before sealing to model a signed grant whose record was
  # altered afterwards. A record names the contract `EdgeContractRegistryStub` holds active unless
  # `:output_contract` names another, so the gateway's registry admission passes by default and a
  # test that wants a registry withhold still gets a grant signed over the contract it names.

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeDeliveryClaimsV1
  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeDeliveryRenewalV1
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeProductionClaimsV1
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1
  alias ServiceRadarAgentGateway.TestSupport.EdgeContractRegistryStub

  @issuer_id "test-edge-issuer"
  @issuer_key_id "test-edge-key-1"
  @hour_nanos 3_600 * 1_000_000_000

  # The producer a record is attributed to unless a test names another. `trust_document/2` fences it
  # at authority epoch 1 by default, because the gateway withholds a producer it has no fence for.
  @network_scope_id <<0x0190_0000_0001::48, 7::4, 0x001::12, 2::2, 0x5C::62>>
  @producer_assignment_id <<0x0190_0000_0001::48, 7::4, 0x002::12, 2::2, 0xA5::62>>

  def issuer_key_id, do: @issuer_key_id
  def hour_nanos, do: @hour_nanos
  def network_scope_id, do: @network_scope_id
  def producer_assignment_id, do: @producer_assignment_id

  def keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public, private: private}
  end

  def trust_document(public_key, opts \\ []) do
    %{
      "trust_policy_epoch" => 1,
      "keys" => [key_entry(public_key, opts) | Keyword.get(opts, :extra_keys, [])],
      "fences" =>
        opts
        |> Keyword.get(:fences, [{@network_scope_id, @producer_assignment_id, 0, 1}])
        |> Enum.map(fn {scope, assignment, shard, epoch} ->
          %{
            "network_scope_id" => Base.encode64(scope),
            "producer_assignment_id" => Base.encode64(assignment),
            "run_shard" => shard,
            "authority_epoch" => epoch
          }
        end)
    }
  end

  def key_entry(public_key, opts \\ []) do
    %{
      "issuer_id" => Base.encode64(@issuer_id),
      "issuer_key_id" => Base.encode64(Keyword.get(opts, :issuer_key_id, @issuer_key_id)),
      "public_key" => Base.encode64(public_key),
      "purposes" => Keyword.get(opts, :purposes, ~w(production source delivery)),
      "status" => Keyword.get(opts, :status, "valid")
    }
  end

  def uuidv7(millis \\ System.os_time(:millisecond)) do
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
    <<millis::48, 7::4, rand_a::12, 2::2, rand_b::62>>
  end

  def record(private_key, opts \\ []) do
    now = System.os_time(:nanosecond)
    not_before = Keyword.get(opts, :not_before, now - @hour_nanos)
    expires = Keyword.get(opts, :expires, now + @hour_nanos)
    payload = Keyword.get(opts, :payload, "synthetic generic telemetry batch")

    record = %EdgeRecordV1{
      event_id: uuidv7(div(not_before, 1_000_000) + 1),
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      encoded_size: byte_size(payload),
      uncompressed_size: byte_size(payload),
      payload_sha256: :crypto.hash(:sha256, payload),
      output_contract: Keyword.get_lazy(opts, :output_contract, &EdgeContractRegistryStub.contract_ref/0),
      producer_context: %EdgeProducerContext{
        origin_kind: :EDGE_ORIGIN_KIND_AGENT,
        origin_principal_id: Keyword.get(opts, :principal, "agent-1"),
        producer_instance_id: "test-instance",
        producer_assignment_id: Keyword.get(opts, :producer_assignment_id, @producer_assignment_id),
        run_id: uuidv7(),
        run_shard: 0,
        authority_epoch: Keyword.get(opts, :authority_epoch, 1),
        scope_id: uuidv7(),
        scope_sha256: digest(4),
        package_id: "serviceradar.test.package",
        package_sha256: digest(5)
      },
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      network_scope_id: Keyword.get(opts, :network_scope_id, @network_scope_id),
      projected_row_count: 1,
      projected_write_bytes: 256,
      cost_model_version: 1,
      payload: payload
    }

    production =
      record
      |> production_capability(not_before, expires)
      |> sign(Keyword.get(opts, :production_signer, private_key))

    record = %{record | production_capability: production}

    record =
      case Keyword.get(opts, :source) do
        nil -> record
        source_opts -> %{record | source_authorization: source_authorization(record, private_key, source_opts)}
      end

    record = Keyword.get(opts, :mutate, & &1).(record)
    %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
  end

  def frame(record, opts \\ []) do
    bytes = EdgeRecordV1.encode(record)

    %EdgeDeliveryFrameV1{
      spool_id: Keyword.get(opts, :spool_id, :binary.copy(<<0xAB>>, 16)),
      sequence: Keyword.get(opts, :sequence, 1),
      record_sha256: :crypto.hash(:sha256, bytes),
      record_bytes: bytes,
      delivery_capability: Keyword.get(opts, :delivery_capability)
    }
  end

  # A same-spool renewal bound to `record` at `spool_id`/`sequence`, current around now unless
  # overridden.
  def delivery_capability(record, private_key, opts) do
    now = System.os_time(:nanosecond)
    not_before = Keyword.get(opts, :not_before, now - @hour_nanos)
    expires = Keyword.get(opts, :expires, now + @hour_nanos)

    claims = %EdgeDeliveryClaimsV1{
      event_id: Keyword.get(opts, :event_id, record.event_id),
      record_sha256:
        Keyword.get_lazy(opts, :record_sha256, fn -> :crypto.hash(:sha256, EdgeRecordV1.encode(record)) end),
      spool_id: Keyword.fetch!(opts, :spool_id),
      sequence: Keyword.get(opts, :sequence, 1),
      transition:
        {:renewal, %EdgeDeliveryRenewalV1{renewed_not_before_unix_nano: not_before, renewed_expires_unix_nano: expires}}
    }

    sign(envelope({:delivery, claims}, not_before, expires, @issuer_key_id), private_key)
  end

  def sign(capability, private_key) do
    signature = :crypto.sign(:eddsa, :none, CapabilitySigning.signing_bytes(capability), [private_key, :ed25519])
    %{capability | signature: signature}
  end

  defp production_capability(r, not_before, expires) do
    c = r.output_contract
    p = r.producer_context

    envelope(
      {:production,
       %EdgeProductionClaimsV1{
         contract_id: c.contract_id,
         contract_version: c.contract_version,
         contract_bundle_sha256: c.contract_bundle_sha256,
         registry_epoch: c.registry_epoch,
         network_scope_id: r.network_scope_id,
         producer_assignment_id: p.producer_assignment_id,
         traffic_class: r.traffic_class,
         route_profile: r.route_profile,
         origin_kind: p.origin_kind,
         origin_principal_id: p.origin_principal_id,
         producer_instance_id: p.producer_instance_id,
         run_id: p.run_id,
         run_shard: p.run_shard,
         authority_epoch: p.authority_epoch,
         scope_id: p.scope_id,
         scope_sha256: p.scope_sha256,
         package_sha256: p.package_sha256,
         registry_snapshot_sha256: c.registry_snapshot_sha256,
         effective_grant_sha256: c.effective_grant_sha256,
         max_projected_row_count: r.projected_row_count,
         max_projected_write_bytes: r.projected_write_bytes,
         cost_model_version: r.cost_model_version,
         package_id: p.package_id
       }},
      not_before,
      expires,
      @issuer_key_id
    )
  end

  defp source_authorization(r, private_key, opts) do
    p = r.producer_context
    envelope = r.production_capability
    kind = Keyword.get(opts, :kind, :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK)
    context_id = uuidv7()
    scope_id = uuidv7()
    scope_sha256 = digest(6)

    claims = %EdgeSourceClaimsV1{
      kind: kind,
      context_id: context_id,
      scope_id: scope_id,
      scope_sha256: scope_sha256,
      network_scope_id: r.network_scope_id,
      collection_not_before_unix_nano: envelope.not_before_unix_nano,
      collection_expires_unix_nano: Keyword.get(opts, :collection_expires, envelope.expires_at_unix_nano),
      origin_principal_id: p.origin_principal_id,
      producer_instance_id: p.producer_instance_id,
      producer_assignment_id: p.producer_assignment_id,
      run_id: p.run_id,
      run_shard: p.run_shard,
      authority_epoch: p.authority_epoch,
      traffic_class: r.traffic_class,
      route_profile: r.route_profile,
      execution_plan_sha256: Keyword.get(opts, :execution_plan_sha256, ""),
      target_range_sha256: Keyword.get(opts, :target_range_sha256, ""),
      origin_kind: p.origin_kind
    }

    capability =
      {:source, claims}
      |> envelope(
        envelope.not_before_unix_nano,
        envelope.expires_at_unix_nano,
        Keyword.get(opts, :issuer_key_id, @issuer_key_id)
      )
      |> sign(Keyword.get(opts, :signer, private_key))

    %EdgeSourceAuthorizationV1{
      kind: kind,
      capability: capability,
      context_id: context_id,
      scope_id: scope_id,
      scope_sha256: scope_sha256
    }
  end

  defp envelope(claims, not_before, expires, issuer_key_id) do
    %EdgeSignedCapabilityV1{
      capability_version: 1,
      issuer_id: @issuer_id,
      issuer_key_id: issuer_key_id,
      algorithm: "ed25519",
      not_before_unix_nano: not_before,
      expires_at_unix_nano: expires,
      claims: claims
    }
  end

  def digest(seed), do: :crypto.hash(:sha256, <<"edge-record-factory", seed>>)
end
