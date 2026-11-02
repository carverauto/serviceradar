defmodule ServiceRadar.Edge.OutputGrantsDbTest do
  @moduledoc """
  Standing output grants against a real database: the fence lifecycle a grant moves through,
  the config grant an agent on the edge-record pipeline receives, and the gateway trust document
  that admits its records.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.RecordTrust
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.SweepJobs.SweepLeaseSetting

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

    assert {:ok, grant} = OutputGrants.reconcile(ctx.agent, @contract, scope, true)

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
             OutputGrants.reconcile(ctx.agent, @contract, scope, true)

    assert {:ok, %{id: id, authority_epoch: 1}} =
             OutputGrants.reconcile(ctx.agent, @contract, scope, true)

    assert id == grant.id

    assert {:ok, nil} = OutputGrants.reconcile(ctx.agent, @contract, scope, false)
    assert {:ok, %{state: :revoked, authority_epoch: 2}} = OutputGrants.get(ctx.agent, @contract)
    assert {:ok, nil} = OutputGrants.reconcile(ctx.agent, @contract, scope, false)
    assert {:ok, %{authority_epoch: 2}} = OutputGrants.get(ctx.agent, @contract)

    assert {:ok, %{id: ^id, state: :active, authority_epoch: 3}} =
             OutputGrants.reconcile(ctx.agent, @contract, scope, true)

    assert {:ok, %{id: ^id, authority_epoch: 4, network_scope_id: ^other_scope}} =
             OutputGrants.reconcile(ctx.agent, @contract, other_scope, true)
  end

  test "an agent on the edge-record pipeline gets one grant, signed for the UTC day", ctx do
    enable_leasing!(ctx)
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

  test "an agent off the edge-record pipeline gets no grant, and turning it off revokes one",
       ctx do
    assert [] =
             OutputGrants.config_grants(
               ctx.agent,
               ctx.partition.slug,
               DateTime.utc_now(),
               authority(ctx)
             )

    assert {:ok, nil} = OutputGrants.get(ctx.agent, @contract)

    enable_leasing!(ctx)

    assert [_grant] =
             OutputGrants.config_grants(
               ctx.agent,
               ctx.partition.slug,
               DateTime.utc_now(),
               authority(ctx)
             )

    set_leasing!(ctx, false)

    assert [] =
             OutputGrants.config_grants(
               ctx.agent,
               ctx.partition.slug,
               DateTime.utc_now(),
               authority(ctx)
             )

    assert {:ok, %{state: :revoked}} = OutputGrants.get(ctx.agent, @contract)
  end

  test "the gateway trust document fences a grant and binds its agent to the grant's scope",
       ctx do
    {:ok, grant} = OutputGrants.reconcile(ctx.agent, @contract, ctx.partition.id, true)
    encoded_grant = grant.id |> Ecto.UUID.dump!() |> Base.encode64()
    encoded_scope = ctx.partition.id |> Ecto.UUID.dump!() |> Base.encode64()

    assert {:ok, document} = RecordTrust.snapshot(ctx.key)
    fence = Enum.find(document["fences"], &(&1["producer_assignment_id"] == encoded_grant))

    assert %{"authority_epoch" => 1, "network_scope_id" => ^encoded_scope, "run_shard" => 0} =
             fence

    assert Enum.find(document["scopes"], &(&1["agent_id"] == ctx.agent)) ==
             %{"agent_id" => ctx.agent, "network_scope_ids" => [encoded_scope]}

    {:ok, nil} = OutputGrants.reconcile(ctx.agent, @contract, ctx.partition.id, false)
    assert {:ok, revoked} = RecordTrust.snapshot(ctx.key)
    fence = Enum.find(revoked["fences"], &(&1["producer_assignment_id"] == encoded_grant))
    assert fence["authority_epoch"] == 2
  end

  defp enable_leasing!(ctx), do: set_leasing!(ctx, true)

  defp set_leasing!(ctx, enabled?) do
    SweepLeaseSetting
    |> Ash.Changeset.for_create(
      :upsert,
      %{scope: :agent, scope_key: ctx.agent, leasing_enabled: enabled?},
      actor: ctx.actor
    )
    |> Ash.create!()
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
