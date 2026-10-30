defmodule ServiceRadar.Edge.ComponentCertificateAuthorityIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificatePolicyKey
  alias ServiceRadar.Edge.RevokedComponentCertificate

  require Ash.Query

  @moduletag :integration

  setup do
    opts = [actor: SystemActor.system(:component_certificate_test)]
    id = "example-core-#{System.unique_integer([:positive])}"
    attrs = %{component_id: id, component_type: "core", partition_id: "example-partition"}
    {:ok, component} = Authority.enroll_component(attrs, opts)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    metadata = %{
      fingerprint: fingerprint(id),
      issuer_fingerprint: fingerprint("invented-issuer"),
      serial_number: "17",
      role: "client",
      expected_generation: 1,
      not_before: DateTime.shift(now, minute: -1),
      not_after: DateTime.shift(now, hour: 1)
    }

    %{component: component, metadata: metadata, opts: opts}
  end

  test "issuance retry and rotation retain predecessor until explicit durable revocation", ctx do
    id = ctx.component.component_id
    assert {:ok, first} = Authority.record_issuance(id, ctx.metadata, ctx.opts)
    assert {:ok, retry} = Authority.record_issuance(id, ctx.metadata, ctx.opts)
    assert retry.fingerprint == first.fingerprint
    assert retry.issued_at == first.issued_at

    wire_metadata = %{
      ctx.metadata
      | not_before: DateTime.to_iso8601(ctx.metadata.not_before),
        not_after: DateTime.to_iso8601(ctx.metadata.not_after)
    }

    assert {:ok, wire_retry} = Authority.record_issuance(id, wire_metadata, ctx.opts)
    assert wire_retry.issued_at == first.issued_at

    assert {:error, :certificate_metadata_conflict} =
             Authority.record_issuance(id, %{ctx.metadata | serial_number: "18"}, ctx.opts)

    successor_metadata = %{ctx.metadata | fingerprint: fingerprint(id <> "-successor")}
    assert {:ok, successor} = Authority.record_issuance(id, successor_metadata, ctx.opts)
    assert {:ok, snapshot} = Authority.snapshot()
    assert first.fingerprint in snapshot.allowed_fingerprints
    assert successor.fingerprint in snapshot.allowed_fingerprints

    assert {:ok, decision} =
             Authority.revoke_certificate(first.fingerprint, "operator-request", ctx.opts)

    assert {:ok, repeated} = Authority.revoke_certificate(first.fingerprint, "retry", ctx.opts)
    assert repeated.id == decision.id
    assert repeated.reason == "operator-request"
    assert {:ok, snapshot} = Authority.snapshot()
    refute first.fingerprint in snapshot.allowed_fingerprints
    assert successor.fingerprint in snapshot.allowed_fingerprints
    assert {:error, :certificate_revoked} = Authority.record_issuance(id, ctx.metadata, ctx.opts)

    assert {:ok, [stored]} =
             RevokedComponentCertificate
             |> Ash.Query.filter(id == ^decision.id)
             |> Ash.read(ctx.opts)

    assert stored.fingerprint == first.fingerprint
    assert stored.revoked_by == ctx.opts[:actor].id
  end

  test "component revocation blocks issuance; re-enrollment never revives the old identity",
       ctx do
    id = ctx.component.component_id
    assert {:ok, first} = Authority.record_issuance(id, ctx.metadata, ctx.opts)
    assert {:ok, %{blocked: true}} = Authority.revoke_component(id, "emergency", ctx.opts)

    assert {:error, :issuance_binding_unavailable} =
             Authority.record_issuance(id, ctx.metadata, ctx.opts)

    assert {:ok, %{generation: 2, blocked: false}} = Authority.reenroll_component(id, ctx.opts)

    assert {:error, :issuance_binding_unavailable} =
             Authority.record_issuance(id, ctx.metadata, ctx.opts)

    assert {:error, :certificate_metadata_conflict} =
             Authority.record_issuance(id, %{ctx.metadata | expected_generation: 2}, ctx.opts)

    fresh = %{
      ctx.metadata
      | expected_generation: 2,
        fingerprint: fingerprint(id <> "-generation-2")
    }

    assert {:ok, second} = Authority.record_issuance(id, fresh, ctx.opts)
    assert {:ok, snapshot} = Authority.snapshot()
    refute first.fingerprint in snapshot.allowed_fingerprints
    assert second.fingerprint in snapshot.allowed_fingerprints
    refute Enum.any?(snapshot.certificates, &(&1.fingerprint == first.fingerprint))
    assert DateTime.diff(snapshot.valid_until, snapshot.generated_at) == 30
    assert snapshot.digest =~ ~r/\A[0-9a-f]{64}\z/

    assert {:ok, old_decisions} =
             RevokedComponentCertificate
             |> Ash.Query.filter(component_id == ^id and generation == 1)
             |> Ash.read(ctx.opts)

    assert Enum.any?(old_decisions, &(&1.reason == "emergency" and is_nil(&1.fingerprint)))
  end

  test "resource boundary rejects stale issuance and requires edge ownership and permission",
       ctx do
    assert {:ok, _} =
             Authority.revoke_component(ctx.component.component_id, "emergency", ctx.opts)

    attrs = Map.put(ctx.metadata, :component_id, ctx.component.component_id)

    assert {:error, _} =
             ComponentCertificate
             |> Ash.Changeset.for_create(:record_issuance, attrs, ctx.opts)
             |> Ash.create(ctx.opts)

    edge = %{
      component_id: "example-leaf-#{System.unique_integer([:positive])}",
      component_type: "nats-leaf",
      partition_id: "example-partition"
    }

    assert {:error, _} = Authority.enroll_component(edge, ctx.opts)
    viewer = %{id: "example-viewer", role: :viewer, permissions: MapSet.new()}

    assert {:error, _} =
             ctx.component
             |> Ash.Changeset.for_update(:reenroll, %{}, actor: viewer)
             |> Ash.update(actor: viewer)
  end

  test "signed policy survives repeated bootstrap and verifies only in its protocol domain",
       ctx do
    assert {:ok, encoded_public_key} = Authority.policy_public_key()
    assert {:ok, <<_::256>> = public_key} = Base.decode64(encoded_public_key)
    replacement_seed = :crypto.strong_rand_bytes(32)
    {replacement_public, _} = :crypto.generate_key(:eddsa, :ed25519, replacement_seed)

    assert {:ok, _} =
             ManagedCertificatePolicyKey
             |> Ash.Changeset.for_create(
               :configure,
               %{
                 public_key: Base.encode64(replacement_public),
                 seed: Base.encode64(replacement_seed)
               },
               ctx.opts
             )
             |> Ash.create(ctx.opts)

    assert {:ok, ^encoded_public_key} = Authority.policy_public_key()
    assert {:ok, envelope} = Authority.sign_snapshot()
    assert {:ok, payload} = Base.decode64(envelope.payload)
    assert {:ok, signature} = Base.decode64(envelope.signature)

    assert :crypto.verify(
             :eddsa,
             :none,
             ["serviceradar.certificate-policy.v1", <<0>>, payload],
             signature,
             [
               public_key,
               :ed25519
             ]
           )

    refute :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519])

    refute :crypto.verify(
             :eddsa,
             :none,
             ["serviceradar.certificate-policy.v1", <<0>>, payload, " "],
             signature,
             [
               public_key,
               :ed25519
             ]
           )

    assert {:ok, decoded} = Jason.decode(payload)

    assert Enum.sort(Map.keys(decoded)) == [
             "allowed_fingerprints",
             "generated_at",
             "nats_permissions",
             "valid_until",
             "version"
           ]

    assert decoded["version"] == 1
    assert {:ok, public_envelope} = Authority.sign_public_snapshot()
    public_payload = Base.decode64!(public_envelope.payload)

    assert public_payload |> Jason.decode!() |> Map.keys() |> Enum.sort() ==
             ["allowed_fingerprints", "generated_at", "valid_until", "version"]

    assert :crypto.verify(
             :eddsa,
             :none,
             ["serviceradar.certificate-policy.v1", <<0>>, public_payload],
             Base.decode64!(public_envelope.signature),
             [public_key, :ed25519]
           )

    viewer = %{id: "example-viewer", role: :viewer, permissions: MapSet.new()}
    assert {:ok, []} = Ash.read(ManagedCertificatePolicyKey, actor: viewer)
  end

  test "infrastructure permissions preserve explicit denies and cannot bypass adoption or generation",
       ctx do
    permissions = %{
      "publish" => ["example.events.>"],
      "subscribe" => [],
      "publish_deny" => ["example.events.private.>"],
      "subscribe_deny" => ["$SYS.>"]
    }

    id = ctx.component.component_id
    assert {:ok, certificate} = Authority.record_issuance(id, ctx.metadata, ctx.opts)
    assert {:ok, initial} = Authority.snapshot()
    refute Map.has_key?(initial.nats_permissions, certificate.fingerprint)
    assert {:ok, _} = Authority.set_infrastructure_permissions(id, 1, permissions, ctx.opts)
    assert {:ok, snapshot} = Authority.snapshot()

    assert snapshot.nats_permissions[certificate.fingerprint] == %{
             publish: ["example.events.>"],
             subscribe: [],
             publish_deny: ["example.events.private.>"],
             subscribe_deny: ["$SYS.>"]
           }

    viewer = %{id: "example-viewer", role: :viewer, permissions: MapSet.new()}

    assert {:error, _} =
             Authority.set_infrastructure_permissions(id, 1, permissions, actor: viewer)

    assert {:error, _} =
             Authority.set_infrastructure_permissions(
               id,
               1,
               Map.delete(permissions, "subscribe"),
               ctx.opts
             )

    assert {:error, _} =
             Authority.set_infrastructure_permissions(
               id,
               1,
               Map.put(permissions, "allow_responses", true),
               ctx.opts
             )

    assert {:error, _} =
             Authority.set_infrastructure_permissions(
               id,
               1,
               Map.put(permissions, "publish", ["example.>.events"]),
               ctx.opts
             )

    assert {:ok, _} = Authority.revoke_component(id, "operator-request", ctx.opts)
    assert {:ok, _} = Authority.reenroll_component(id, ctx.opts)
    assert {:error, _} = Authority.set_infrastructure_permissions(id, 1, permissions, ctx.opts)
    assert {:ok, record} = Ash.get(ServiceRadar.Edge.ManagedComponent, id, ctx.opts)
    assert record.nats_permissions == permissions

    attrs = %{
      component_id: "example-server-#{Ecto.UUID.generate()}",
      component_type: "nats-server",
      partition_id: "example-partition",
      permissions: permissions
    }

    assert {:ok, adopted} = Authority.adopt_infrastructure_component(attrs, ctx.opts)
    assert adopted.nats_permissions == permissions

    assert {:error, _} =
             Authority.adopt_infrastructure_component(
               %{
                 attrs
                 | component_id: "example-leaf-#{Ecto.UUID.generate()}",
                   component_type: "nats-leaf"
               },
               ctx.opts
             )

    assert {:error, _} =
             attrs
             |> Map.delete(:permissions)
             |> Map.put(:component_id, "example-unadopted-#{Ecto.UUID.generate()}")
             |> Map.put(:nats_permissions, permissions)
             |> Authority.enroll_component(ctx.opts)
  end

  defp fingerprint(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
