defmodule ServiceRadar.Edge.OutputGrantsDbTest do
  @moduledoc """
  Standing output grants against a real database: the fence lifecycle a grant moves through,
  the config grant an agent on the edge-record pipeline receives, and the gateway trust document
  that admits its records.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.ComponentCertificateAuthority
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.RecordTrust
  alias ServiceRadar.Edge.RecoveryAssignmentEvidence
  alias ServiceRadar.Edge.RecoveryAssignments
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition

  @moduletag :integration
  @contract "serviceradar.metrics.batch"

  setup do
    actor = ServiceRadar.Actors.SystemActor.system(:output_grants_test)
    slug = "grants-#{System.unique_integer([:positive])}"

    partition =
      Partition
      |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
      |> Ash.create!()

    {:ok,
     actor: actor,
     partition: partition,
     agent: "agent-grant-#{System.unique_integer([:positive])}",
     key: IssuerKey.from_seed(:binary.copy(<<0x42>>, 32))}
  end

  test "a missing or mismatched grant is refused and any other lookup failure is raised", ctx do
    scope = ctx.partition.id

    assert {:ok, grant} = OutputGrants.reconcile(ctx.agent, @contract, scope)

    assert :ok ==
             OutputGrants.check_current(
               grant.id,
               ctx.agent,
               @contract,
               scope,
               grant.authority_epoch
             )

    assert {:error, :output_grant_not_current} =
             OutputGrants.check_current(Ash.UUID.generate(), ctx.agent, @contract, scope, 1)

    assert {:error, :output_grant_not_current} =
             OutputGrants.check_current(
               grant.id,
               "other-#{ctx.agent}",
               @contract,
               scope,
               grant.authority_epoch
             )

    assert {:error, :output_grant_not_current} =
             OutputGrants.check_current(
               grant.id,
               ctx.agent,
               @contract,
               scope,
               grant.authority_epoch + 1
             )

    # A primary key Ash cannot cast is a lookup failure, not a missing grant.
    assert_raise Ash.Error.Invalid, fn ->
      OutputGrants.check_current("not-a-uuid", ctx.agent, @contract, scope, 1)
    end
  end

  test "a grant's epoch moves only when it is revoked, reissued or moved to another scope", ctx do
    scope = ctx.partition.id
    other_scope = Ash.UUID.generate()

    assert {:ok, %{authority_epoch: 1, state: :active} = grant} =
             OutputGrants.reconcile(ctx.agent, @contract, scope)

    assert {:ok, %{id: id, authority_epoch: 1}} =
             OutputGrants.reconcile(ctx.agent, @contract, scope)

    assert id == grant.id

    assert {:ok, 1} = OutputGrants.revoke_agent(ctx.agent)
    assert {:ok, %{state: :revoked, authority_epoch: 2}} = OutputGrants.get(ctx.agent, @contract)
    assert {:ok, 0} = OutputGrants.revoke_agent(ctx.agent)
    assert {:ok, %{authority_epoch: 2}} = OutputGrants.get(ctx.agent, @contract)

    assert {:ok, %{id: ^id, state: :active, authority_epoch: 3}} =
             OutputGrants.reconcile(ctx.agent, @contract, scope)

    assert {:ok, %{id: ^id, authority_epoch: 4, network_scope_id: ^other_scope}} =
             OutputGrants.reconcile(ctx.agent, @contract, other_scope)
  end

  test "an agent gets one grant per standing contract, signed for the UTC day", ctx do
    morning = ~U[2026-11-01 01:00:00Z]
    evening = ~U[2026-11-01 23:00:00Z]

    assert [config_grant] =
             OutputGrants.config_grants(ctx.agent, ctx.partition.slug, morning, authority(ctx))

    assert config_grant.contract_id == @contract

    assert [same_day] =
             OutputGrants.config_grants(ctx.agent, ctx.partition.slug, evening, authority(ctx))

    assert same_day == config_grant

    capability = EdgeSignedCapabilityV1.decode(config_grant.production_capability)
    assert CapabilitySigning.verify(capability, :production, ctx.key.public_key)

    assert capability.not_before_unix_nano ==
             DateTime.to_unix(~U[2026-10-31 23:55:00Z], :nanosecond)

    assert capability.expires_at_unix_nano ==
             DateTime.to_unix(~U[2026-11-09 00:00:00Z], :nanosecond)

    {:production, claims} = capability.claims
    {:ok, grant} = OutputGrants.get(ctx.agent, @contract)
    assert claims.producer_assignment_id == Ecto.UUID.dump!(grant.id)
    assert claims.origin_principal_id == ctx.agent
    assert claims.authority_epoch == grant.authority_epoch
    assert claims.network_scope_id == Ecto.UUID.dump!(ctx.partition.id)
  end

  test "an agent in the default partition gets a grant on an install that created no partition",
       ctx do
    # Agents that report no partition report "default"; no test or operator created it here,
    # and no settings row exists.
    assert [_grant] =
             OutputGrants.config_grants(ctx.agent, "default", DateTime.utc_now(), authority(ctx))

    assert {:ok, %{id: default_scope}} = Partition.get_by_slug("default", actor: ctx.actor)

    assert {:ok, %{state: :active, network_scope_id: ^default_scope}} =
             OutputGrants.get(ctx.agent, @contract)
  end

  test "the delivered grant has historical negative evidence before config returns, and damaged evidence withholds reissue",
       ctx do
    [delivered] =
      OutputGrants.config_grants(
        ctx.agent,
        ctx.partition.slug,
        DateTime.utc_now(),
        authority(ctx)
      )

    capability = EdgeSignedCapabilityV1.decode(delivered.production_capability)
    {:production, claims} = capability.claims
    {:ok, entry} = RecoveryAssignmentEvidence.standing(capability, ctx.key.public_key)

    span = %Serviceradar.Edge.V1.EdgeClassificationSpanV1{
      from_sequence: 1,
      through_sequence: 1,
      classification:
        {:attributed_passive,
         %Serviceradar.Edge.V1.EdgeAttributedPassiveV1{
           identity: %Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1{
             producer_assignment_id: claims.producer_assignment_id,
             run_id: claims.run_id,
             run_shard: claims.run_shard,
             authority_epoch: claims.authority_epoch,
             production_scope_id: claims.scope_id,
             scope_sha256: claims.scope_sha256,
             contract_bundle_sha256: claims.contract_bundle_sha256
           }
         }}
    }

    assert {:not_scheduled, %{"reason" => "standing_output_grant"}} =
             RecoveryAssignments.lookup(claims.network_scope_id, ctx.agent, span)

    assert {:ok, 1} = OutputGrants.revoke_agent(ctx.agent)

    assert {:not_scheduled, _} =
             RecoveryAssignments.lookup(claims.network_scope_id, ctx.agent, span)

    # Reissue establishes a different epoch; damage only that test-owned original.
    assert [_] =
             OutputGrants.config_grants(
               ctx.agent,
               ctx.partition.slug,
               DateTime.utc_now(),
               authority(ctx)
             )

    assert %{num_rows: 1} =
             ServiceRadar.Repo.query!(
               "UPDATE platform.edge_recovery_assignment_issuances SET evidence = '{}' WHERE mapping_key -> 'trust_namespace' = $1::jsonb AND mapping_key != $2::jsonb",
               [entry.key["trust_namespace"], entry.key]
             )

    assert [] =
             OutputGrants.config_grants(
               ctx.agent,
               ctx.partition.slug,
               DateTime.utc_now(),
               authority(ctx)
             )

    assert {:not_scheduled, _} =
             RecoveryAssignments.lookup(claims.network_scope_id, ctx.agent, span)
  end

  test "an agent whose partition has no row gets no grant, and core creates no partition", ctx do
    slug = "missing-#{System.unique_integer([:positive])}"

    assert [] = OutputGrants.config_grants(ctx.agent, slug, DateTime.utc_now(), authority(ctx))
    assert {:ok, nil} = OutputGrants.get(ctx.agent, @contract)
    assert {:error, _} = Partition.get_by_slug(slug, actor: ctx.actor)

    # Once an operator creates the partition, the next config carries the grant.
    Partition
    |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: ctx.actor)
    |> Ash.create!()

    assert [_grant] =
             OutputGrants.config_grants(ctx.agent, slug, DateTime.utc_now(), authority(ctx))
  end

  test "superseding an agent's identity revokes its grants, and its next config reissues them",
       ctx do
    agent = register_agent!(ctx)
    {:ok, before} = OutputGrants.reconcile(ctx.agent, @contract, ctx.partition.id)

    agent
    |> Ash.Changeset.for_update(:supersede, %{superseded_by: "replacement-#{ctx.agent}"})
    |> Ash.update!(actor: ctx.actor)

    assert {:ok, %{state: :revoked} = revoked} = OutputGrants.get(ctx.agent, @contract)
    assert revoked.authority_epoch == before.authority_epoch + 1

    # A revived identity fetches its config again, which reactivates the grant under a new epoch.
    assert [_grant] =
             OutputGrants.config_grants(
               ctx.agent,
               ctx.partition.slug,
               DateTime.utc_now(),
               authority(ctx)
             )

    assert {:ok, %{state: :active, authority_epoch: epoch}} =
             OutputGrants.get(ctx.agent, @contract)

    assert epoch == revoked.authority_epoch + 1
  end

  test "revoking a managed agent's certificate revokes its grants", ctx do
    component = managed_agent!(ctx)
    {:ok, before} = OutputGrants.reconcile(ctx.agent, @contract, ctx.partition.id)

    assert {:ok, _component} =
             ComponentCertificateAuthority.revoke_component(
               component.component_id,
               "operator-request",
               actor: ctx.actor
             )

    assert {:ok, %{state: :revoked} = revoked} = OutputGrants.get(ctx.agent, @contract)
    assert revoked.authority_epoch == before.authority_epoch + 1
  end

  test "the gateway trust document fences a grant and binds its agent to the grant's scope",
       ctx do
    {:ok, grant} = OutputGrants.reconcile(ctx.agent, @contract, ctx.partition.id)
    encoded_grant = grant.id |> Ecto.UUID.dump!() |> Base.encode64()
    encoded_scope = ctx.partition.id |> Ecto.UUID.dump!() |> Base.encode64()

    assert {:ok, document} = RecordTrust.snapshot(ctx.key)
    fence = Enum.find(document["fences"], &(&1["producer_assignment_id"] == encoded_grant))

    assert %{"authority_epoch" => 1, "network_scope_id" => ^encoded_scope, "run_shard" => 0} =
             fence

    assert Enum.find(document["scopes"], &(&1["agent_id"] == ctx.agent)) ==
             %{"agent_id" => ctx.agent, "network_scope_ids" => [encoded_scope]}

    {:ok, 1} = OutputGrants.revoke_agent(ctx.agent)
    assert {:ok, revoked} = RecordTrust.snapshot(ctx.key)
    fence = Enum.find(revoked["fences"], &(&1["producer_assignment_id"] == encoded_grant))
    assert fence["authority_epoch"] == 2
  end

  defp register_agent!(ctx) do
    Agent
    |> Ash.Changeset.for_create(:register, %{uid: ctx.agent, name: ctx.agent})
    |> Ash.create!(actor: ctx.actor)
  end

  defp managed_agent!(ctx) do
    register_agent!(ctx)

    {:ok, component} =
      ComponentCertificateAuthority.enroll_component(
        %{
          component_id: ctx.agent,
          component_type: "agent",
          partition_id: ctx.partition.slug,
          host_agent_id: ctx.agent
        },
        actor: ctx.actor
      )

    component
  end

  defp authority(ctx) do
    {:ok,
     %{
       key: ctx.key,
       contracts: [
         %{
           contract_id: @contract,
           contract_version: 1,
           contract_bundle_sha256: :crypto.hash(:sha256, "metrics-bundle"),
           registry_epoch: 1,
           registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
           cost_model_version: 1,
           max_projected_row_count: 10_000,
           max_projected_write_bytes: 10_240_000
         }
       ]
     }}
  end
end
