defmodule ServiceRadar.Edge.ComponentCertificateAuthorityIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.InfrastructureCertificateAdoption
  alias ServiceRadar.Edge.ManagedCertificatePolicyKey
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Edge.RevokedComponentCertificate
  alias ServiceRadar.Edge.RuntimeCertificateRotation

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

    for key <- [:subject, "subject"] do
      assert {:error, %Ash.Error.Invalid{}} =
               Authority.record_issuance(id, Map.put(ctx.metadata, key, "CN=example"), ctx.opts)
    end

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
    assert {:ok, record} = Ash.get(ManagedComponent, id, ctx.opts)
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

  test "adopts a static NATS client under its projected grant and rolls back a duplicate",
       ctx do
    %{pem: pem, der: der} = self_signed_certificate()
    id = "example-gateway-#{System.unique_integer([:positive])}"

    attrs = %{
      component_id: id,
      component_type: "nats-client",
      partition_id: "example-partition",
      certificate_pem: pem,
      permissions: %{
        "publish" => %{"allow" => ["metrics.example.>"], "deny" => []},
        "subscribe" => %{"allow" => [], "deny" => ["$SYS.>", "flow.example.>"]}
      }
    }

    viewer = %{id: "example-viewer", role: :viewer, permissions: MapSet.new()}

    operator = %{
      id: "example-operator",
      role: :operator,
      permissions: MapSet.new(["settings.edge.manage"])
    }

    assert {:error, _} = Authority.adopt_existing_certificate(attrs, actor: viewer)

    assert {:ok, %{component: component, certificate: certificate}} =
             Authority.adopt_existing_certificate(attrs, actor: operator)

    assert component.generation_started_by == "example-operator"
    assert component.host_agent_id == nil
    assert component.nats_permissions["publish"] == ["metrics.example.>"]
    assert component.nats_permissions["subscribe"] == [">"]
    assert component.nats_permissions["subscribe_deny"] == ["$SYS.>", "flow.example.>"]
    assert certificate.fingerprint == fingerprint(der)
    assert certificate.issuer_fingerprint == certificate.fingerprint
    assert certificate.role == "client"
    assert certificate.generation == 1
    assert "CN=example-gateway" in String.split(certificate.subject, ",")

    assert {:ok, snapshot} = Authority.snapshot()
    assert certificate.fingerprint in snapshot.allowed_fingerprints
    assert snapshot.nats_permissions[certificate.fingerprint][:subscribe] == [">"]

    assert snapshot.nats_permissions[certificate.fingerprint][:subscribe_deny] == [
             "$SYS.>",
             "flow.example.>"
           ]

    narrowed = Map.put(component.nats_permissions, "publish", ["metrics.example.health"])
    assert {:ok, _} = Authority.set_infrastructure_permissions(id, 1, narrowed, actor: operator)

    replay_attrs = %{attrs | component_id: id <> " "}

    assert {:ok, %{component: replayed_component, certificate: replay}} =
             Authority.adopt_existing_certificate(replay_attrs, actor: operator)

    assert replayed_component.nats_permissions == narrowed
    assert replay.subject == certificate.subject
    assert replay.issued_at == certificate.issued_at

    duplicate_id = "example-gateway-#{System.unique_integer([:positive])}"

    assert {:error, :certificate_metadata_conflict} =
             Authority.adopt_existing_certificate(
               %{attrs | component_id: duplicate_id},
               actor: operator
             )

    assert {:ok, []} =
             ManagedComponent
             |> Ash.Query.filter(component_id == ^duplicate_id)
             |> Ash.read(ctx.opts)

    assert {:ok, stored} = Ash.get(ManagedComponent, id, ctx.opts)
    assert stored.component_id == id
  end

  # First adoption of a chart identity must not add a second certificate for a
  # subject another caller has already recorded.
  test "adopt_unheld_certificate writes nothing when a recorded certificate holds the subject",
       ctx do
    shared = ~c"example-shared-#{System.unique_integer([:positive])}"
    held = self_signed_certificate(shared)
    late = self_signed_certificate(shared)
    refute fingerprint(held.der) == fingerprint(late.der)

    holder_id = "example-holder-#{System.unique_integer([:positive])}"
    late_id = "example-late-#{System.unique_integer([:positive])}"

    assert {:ok, %{certificate: first}} =
             Authority.adopt_existing_certificate(adoption(holder_id, held.pem), ctx.opts)

    assert {:error, :subject_held} =
             Authority.adopt_unheld_certificate(adoption(late_id, late.pem), ctx.opts)

    assert {:ok, []} =
             ManagedComponent |> Ash.Query.filter(component_id == ^late_id) |> Ash.read(ctx.opts)

    assert {:ok, [only]} =
             ComponentCertificate
             |> Ash.Query.filter(subject == ^first.subject)
             |> Ash.read(ctx.opts)

    assert only.fingerprint == first.fingerprint

    # A subject nobody holds is adopted through the same entry point.
    free = self_signed_certificate(~c"example-free-#{System.unique_integer([:positive])}")
    free_id = "example-free-#{System.unique_integer([:positive])}"

    assert {:ok, %{certificate: adopted}} =
             Authority.adopt_unheld_certificate(adoption(free_id, free.pem), ctx.opts)

    assert adopted.fingerprint == fingerprint(free.der)
    assert adopted.component_id == free_id
  end

  # The check above is only safe if every writer of a subject and the unheld
  # check wait on the same lock. The sandbox holds one transaction for the
  # whole test, so a transaction-scoped lock taken by a call is still held
  # afterwards and can be counted.
  test "a subject's writers and the unheld check take one lock per subject", ctx do
    shared = ~c"example-locked-#{System.unique_integer([:positive])}"
    held = self_signed_certificate(shared)
    late = self_signed_certificate(shared)
    other = self_signed_certificate(~c"example-other-#{System.unique_integer([:positive])}")

    before = advisory_locks()

    assert {:ok, _adopted} =
             Authority.adopt_existing_certificate(
               adoption("example-lock-a-#{System.unique_integer([:positive])}", held.pem),
               ctx.opts
             )

    after_first = advisory_locks()
    assert MapSet.size(MapSet.difference(after_first, before)) == 1

    assert {:ok, _adopted} =
             Authority.adopt_unheld_certificate(
               adoption("example-lock-b-#{System.unique_integer([:positive])}", other.pem),
               ctx.opts
             )

    after_other = advisory_locks()
    assert MapSet.size(MapSet.difference(after_other, after_first)) == 1

    assert {:error, :subject_held} =
             Authority.adopt_unheld_certificate(
               adoption("example-lock-c-#{System.unique_integer([:positive])}", late.pem),
               ctx.opts
             )

    # The refused attempt waited on the lock the first writer took, not a new one.
    assert advisory_locks() == after_other
  end

  test "successor replay fills only a missing subject and preserves a recorded spelling", ctx do
    id = ctx.component.component_id
    fields = ComponentCertificate.__schema__(:fields)

    for initial <- [nil, "CN=example-recorded-spelling"] do
      %{pem: pem} = self_signed_certificate()
      input = %{certificate_pem: pem}
      assert {:ok, issuance} = InfrastructureCertificateAdoption.prepare_certificate(input)
      assert "CN=example-gateway" in String.split(issuance.subject, ",")
      attrs = Map.merge(issuance, %{component_id: id, expected_generation: 1, subject: initial})

      certificate =
        ComponentCertificate
        |> Ash.Changeset.for_create(:record_issuance, attrs, ctx.opts)
        |> Ash.create!(ctx.opts)

      assert certificate.subject == initial
      expected = certificate |> Map.take(fields) |> Map.put(:subject, initial || issuance.subject)

      assert {:ok, %{certificate: replay}} =
               Authority.record_infrastructure_successor(id, input, ctx.opts)

      assert Map.take(replay, fields) == expected

      assert {:error, _} =
               certificate
               |> Ash.Changeset.for_update(:fill_subject, %{subject: "CN=example-new"}, ctx.opts)
               |> Ash.update(ctx.opts)

      assert {:ok, stored} = Ash.get(ComponentCertificate, certificate.fingerprint, ctx.opts)
      assert Map.take(stored, fields) == expected
    end
  end

  test "revoked legacy subjects are filled only for an authorized owner and stay revoked", ctx do
    id = ctx.component.component_id
    %{pem: pem} = self_signed_certificate()
    input = %{certificate_pem: pem}
    assert {:ok, issuance} = InfrastructureCertificateAdoption.prepare_certificate(input)

    attrs = issuance |> Map.delete(:subject) |> Map.put(:expected_generation, 1)
    assert {:ok, legacy} = Authority.record_issuance(id, attrs, ctx.opts)
    assert is_nil(legacy.subject)

    assert {:ok, revocation} =
             Authority.revoke_certificate(legacy.fingerprint, "retired", ctx.opts)

    viewer = %{id: "example-viewer", role: :viewer, permissions: MapSet.new()}
    assert {:error, _} = Authority.record_infrastructure_successor(id, input, actor: viewer)

    assert {:error, :unknown_component} =
             Authority.record_infrastructure_successor(id <> "-other", input, ctx.opts)

    assert {:ok, %{subject: nil}} = Ash.get(ComponentCertificate, legacy.fingerprint, ctx.opts)

    assert {:error, :certificate_revoked} =
             Authority.record_infrastructure_successor(id, input, ctx.opts)

    assert {:ok, stored} = Ash.get(ComponentCertificate, legacy.fingerprint, ctx.opts)
    assert stored.subject == issuance.subject
    assert {:ok, decision} = Ash.get(RevokedComponentCertificate, revocation.id, ctx.opts)
    assert decision.fingerprint == legacy.fingerprint
    assert {:ok, snapshot} = Authority.snapshot()
    refute legacy.fingerprint in snapshot.allowed_fingerprints
  end

  test "records an infrastructure successor at the current generation and keeps the grant",
       ctx do
    %{pem: pem} = self_signed_certificate()
    next = self_signed_certificate(~c"example-gateway-next")
    later = self_signed_certificate(~c"example-gateway-later")
    id = "example-gateway-#{System.unique_integer([:positive])}"

    attrs = %{
      component_id: id,
      component_type: "agent-gateway",
      partition_id: "example-partition",
      certificate_pem: pem,
      permissions: %{
        "publish" => %{"allow" => ["metrics.example.>"], "deny" => []},
        "subscribe" => %{"allow" => [], "deny" => ["$SYS.>", "flow.example.>"]}
      }
    }

    operator = %{
      id: "example-operator",
      role: :operator,
      permissions: MapSet.new(["settings.edge.manage"])
    }

    viewer = %{id: "example-viewer", role: :viewer, permissions: MapSet.new()}

    assert {:ok, %{certificate: first}} =
             Authority.adopt_existing_certificate(attrs, actor: operator)

    assert {:error, _} =
             Authority.record_infrastructure_successor(id, %{certificate_pem: next.pem},
               actor: viewer
             )

    assert {:error, :unknown_component} =
             Authority.record_infrastructure_successor(
               "example-missing-#{System.unique_integer([:positive])}",
               %{certificate_pem: next.pem},
               actor: operator
             )

    assert {:error, :private_key} =
             Authority.record_infrastructure_successor(
               id,
               %{certificate_pem: next.pem <> private_key_pem()},
               actor: operator
             )

    collector_id = "example-collector-#{System.unique_integer([:positive])}"

    assert {:ok, %{num_rows: 1}} =
             ServiceRadar.Repo.query(
               """
               INSERT INTO platform.managed_components
                 (component_id, component_type, partition_id, generation_started_by)
               VALUES ($1, 'log-collector', 'example-partition', 'example-operator')
               """,
               [collector_id]
             )

    assert {:error, :not_infrastructure} =
             Authority.record_infrastructure_successor(
               collector_id,
               %{certificate_pem: next.pem},
               actor: operator
             )

    assert {:ok, []} = certificates(collector_id, ctx.opts)

    assert {:error, :unknown_certificate} =
             Authority.record_infrastructure_successor(
               ctx.component.component_id,
               %{certificate_pem: next.pem},
               ctx.opts
             )

    assert {:ok, %{certificate: successor}} =
             Authority.record_infrastructure_successor(id, %{certificate_pem: next.pem},
               actor: operator
             )

    assert successor.fingerprint == fingerprint(next.der)
    assert successor.generation == 1
    refute successor.fingerprint == first.fingerprint
    assert "CN=example-gateway" in String.split(first.subject, ",")
    assert "CN=example-gateway-next" in String.split(successor.subject, ",")

    assert {:ok, stored} = Ash.get(ManagedComponent, id, actor: operator)
    assert stored.generation == 1
    assert stored.blocked == false
    assert stored.nats_permissions["publish"] == ["metrics.example.>"]
    assert stored.nats_permissions["subscribe"] == [">"]
    assert stored.nats_permissions["subscribe_deny"] == ["$SYS.>", "flow.example.>"]

    assert {:ok, snapshot} = Authority.snapshot()
    assert first.fingerprint in snapshot.allowed_fingerprints
    assert successor.fingerprint in snapshot.allowed_fingerprints
    assert snapshot.nats_permissions[first.fingerprint][:subscribe] == [">"]
    assert snapshot.nats_permissions[successor.fingerprint][:subscribe] == [">"]

    assert {:ok, recorded} = certificates(id, ctx.opts)

    assert Enum.sort(Enum.map(recorded, & &1.fingerprint)) ==
             Enum.sort([first.fingerprint, successor.fingerprint])

    assert {:ok, []} =
             RevokedComponentCertificate
             |> Ash.Query.filter(component_id == ^id)
             |> Ash.read(ctx.opts)

    assert {:ok, %{generation: 2}} = Authority.reenroll_component(id, ctx.opts)

    assert {:ok, %{certificate: renewed}} =
             Authority.record_infrastructure_successor(id, %{certificate_pem: later.pem},
               actor: operator
             )

    assert renewed.generation == 2
    assert renewed.fingerprint == fingerprint(later.der)
    assert {:ok, stored} = Ash.get(ManagedComponent, id, ctx.opts)
    assert stored.generation == 2
    assert stored.nats_permissions["publish"] == ["metrics.example.>"]
    assert stored.nats_permissions["subscribe"] == [">"]

    assert {:ok, snapshot} = Authority.snapshot()
    refute first.fingerprint in snapshot.allowed_fingerprints
    refute successor.fingerprint in snapshot.allowed_fingerprints
    assert renewed.fingerprint in snapshot.allowed_fingerprints
    assert snapshot.nats_permissions[renewed.fingerprint][:publish] == ["metrics.example.>"]

    assert {:ok, %{blocked: true}} = Authority.revoke_component(id, "emergency", ctx.opts)

    assert {:error, :issuance_binding_unavailable} =
             Authority.record_infrastructure_successor(
               id,
               %{certificate_pem: self_signed_certificate(~c"example-gateway-blocked").pem},
               actor: operator
             )

    assert {:ok, snapshot} = Authority.snapshot()
    refute renewed.fingerprint in snapshot.allowed_fingerprints
  end

  # The chart reissues every runtime certificate from the same CA when its
  # layout changes. An adopted component is admitted by recorded fingerprint, so
  # the reissued certificate must be recorded from the generator's rotation
  # record or the component loses NATS access.
  @tag :tmp_dir
  test "records a chart-rotated certificate on the adopted component that held its predecessor",
       ctx do
    root = :public_key.pkix_test_root_cert(~c"example-root", [])

    other_root = self_signed_certificate(~c"example-other-root")
    adopted = issued_certificate(root)
    rotated = issued_certificate(root)
    foreign = issued_certificate(:public_key.pkix_test_root_cert(~c"example-foreign-root", []))
    id = "example-core-#{System.unique_integer([:positive])}"

    operator = %{
      id: "example-operator",
      role: :operator,
      permissions: MapSet.new(["settings.edge.manage"])
    }

    assert {:ok, %{certificate: first}} =
             Authority.adopt_existing_certificate(
               %{
                 component_id: id,
                 component_type: "core",
                 partition_id: "example-partition",
                 certificate_pem: adopted.pem,
                 permissions: %{
                   "publish" => %{"allow" => ["metrics.example.>"], "deny" => []},
                   "subscribe" => %{"allow" => ["events.example.>"], "deny" => []}
                 }
               },
               actor: operator
             )

    path = rotation_record(ctx.tmp_dir, first.fingerprint, rotated, other_root, foreign)

    assert {:ok, outcomes} = RuntimeCertificateRotation.reconcile(path)

    assert {:recorded, rotated.fingerprint, id} in outcomes
    assert {:skipped, fingerprint(other_root.der), :predecessor_not_recorded} in outcomes
    assert {:refused, foreign.fingerprint, :untrusted_issuer} in outcomes

    assert {:ok, snapshot} = Authority.snapshot()
    assert first.fingerprint in snapshot.allowed_fingerprints
    assert rotated.fingerprint in snapshot.allowed_fingerprints
    refute foreign.fingerprint in snapshot.allowed_fingerprints

    assert snapshot.nats_permissions[rotated.fingerprint] ==
             snapshot.nats_permissions[first.fingerprint]

    assert {:ok, %{generation: 1}} = Ash.get(ManagedComponent, id, ctx.opts)

    # Revoking the replaced certificate keeps its recorded replacement, and a
    # revoked certificate names no further replacement.
    assert {:ok, _} = Authority.revoke_certificate(first.fingerprint, "rotated", ctx.opts)
    assert {:ok, outcomes} = RuntimeCertificateRotation.reconcile(path)
    assert {:recorded, rotated.fingerprint, id} in outcomes

    later = issued_certificate(root)

    assert {:error, :certificate_revoked} =
             Authority.record_rotated_infrastructure_successor(
               first.fingerprint,
               %{certificate_pem: later.pem},
               ctx.opts
             )

    # A certificate superseded by re-enrollment names no replacement either.
    assert {:ok, %{generation: 2}} = Authority.reenroll_component(id, ctx.opts)

    assert {:error, :stale_generation} =
             Authority.record_rotated_infrastructure_successor(
               rotated.fingerprint,
               %{certificate_pem: later.pem},
               ctx.opts
             )

    assert {:ok, outcomes} = RuntimeCertificateRotation.reconcile(path)
    assert {:refused, rotated.fingerprint, :stale_generation} in outcomes

    assert {:ok, recorded} = certificates(id, ctx.opts)

    assert Enum.sort(Enum.map(recorded, & &1.fingerprint)) ==
             Enum.sort([first.fingerprint, rotated.fingerprint])
  end

  defp issued_certificate(root) do
    data = :public_key.pkix_test_data(%{root: root, peer: [], intermediates: []})
    [issuer | _] = data[:cacerts]

    %{
      der: data[:cert],
      fingerprint: fingerprint(data[:cert]),
      pem:
        :public_key.pem_encode([
          {:Certificate, data[:cert], :not_encrypted},
          {:Certificate, issuer, :not_encrypted}
        ])
    }
  end

  # The record names the adopted certificate's replacement, a replacement for a
  # certificate that was never adopted, and one from another CA.
  defp rotation_record(dir, adopted_fingerprint, rotated, other_root, foreign) do
    entries = [
      %{
        previous_fingerprint: adopted_fingerprint,
        fingerprint: rotated.fingerprint,
        certificate_pem: rotated.pem
      },
      %{
        previous_fingerprint: fingerprint("example-never-adopted"),
        fingerprint: fingerprint(other_root.der),
        certificate_pem: other_root.pem
      },
      %{
        previous_fingerprint: adopted_fingerprint,
        fingerprint: foreign.fingerprint,
        certificate_pem: foreign.pem
      }
    ]

    path = Path.join(dir, "runtime-cert-rotation.json")
    File.write!(path, Jason.encode!(%{version: 1, certificates: entries}))
    path
  end

  defp certificates(component_id, opts) do
    ComponentCertificate
    |> Ash.Query.filter(component_id == ^component_id)
    |> Ash.read(opts)
  end

  defp private_key_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  end

  defp adoption(component_id, pem) do
    %{
      component_id: component_id,
      component_type: "nats-client",
      partition_id: "example-partition",
      certificate_pem: pem,
      permissions: %{
        "publish" => %{"allow" => ["metrics.example.>"], "deny" => []},
        "subscribe" => %{"allow" => ["_INBOX.>"], "deny" => []}
      }
    }
  end

  defp advisory_locks do
    {:ok, %{rows: rows}} =
      ServiceRadar.Repo.query("""
      SELECT classid, objid, objsubid FROM pg_locks
      WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted
      """)

    MapSet.new(rows)
  end

  defp self_signed_certificate(name \\ ~c"example-gateway") do
    %{cert: der} = :public_key.pkix_test_root_cert(name, [])

    %{
      der: der,
      pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    }
  end

  defp fingerprint(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
