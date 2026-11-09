defmodule ServiceRadar.RecoveryAssignmentFixtures do
  @moduledoc false

  alias ServiceRadar.Edge.IssuerKey
  alias Serviceradar.Edge.V1.EdgeAttributedActiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedPassiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeProductionClaimsV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.SweepLeaseSlotV1

  def fixture(kind \\ :sweep) do
    key = IssuerKey.from_seed(:binary.copy(<<0x63>>, 32))
    scope = uuid()
    agent = "agent-#{System.unique_integer([:positive])}.example.com"

    production = %EdgeProductionClaimsV1{
      contract_id:
        if(kind == :standing,
          do: "serviceradar.metrics.batch",
          else: "serviceradar.sweep.observation"
        ),
      contract_version: 1,
      contract_bundle_sha256: digest(0x31),
      registry_epoch: 1,
      network_scope_id: scope,
      producer_assignment_id: uuid(),
      run_id: uuid(),
      run_shard: 3,
      authority_epoch: 7,
      scope_id: uuid(),
      scope_sha256: digest(0x32),
      origin_principal_id: agent,
      producer_instance_id: agent,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      origin_kind: :EDGE_ORIGIN_KIND_AGENT,
      package_id: "serviceradar.agent.sweep",
      package_sha256: digest(0x33),
      registry_snapshot_sha256: digest(0x34),
      effective_grant_sha256: digest(0x35),
      max_projected_row_count: 10,
      max_projected_write_bytes: 4096,
      cost_model_version: 1
    }

    capability = sign(:production, production, key)
    source = if kind == :sweep, do: source(production, key)
    execution = if source, do: source.context_id, else: uuid()
    plan_id = uuid()

    identity = %EdgeAttributedSpanIdentityV1{
      producer_assignment_id: production.producer_assignment_id,
      run_id: production.run_id,
      run_shard: 3,
      authority_epoch: 7,
      production_scope_id: production.scope_id,
      scope_sha256: digest(0x32),
      contract_bundle_sha256: digest(0x31),
      source:
        if(source,
          do: %EdgeSourceSpanIdentityV1{
            kind: source.kind,
            context_id: execution,
            source_scope_id: source.scope_id,
            source_scope_sha256: digest(0x36)
          }
        )
    }

    classification =
      if source,
        do:
          {:attributed_active,
           %EdgeAttributedActiveV1{identity: identity, range_sha256: digest(0x36)}},
        else: {:attributed_passive, %EdgeAttributedPassiveV1{identity: identity}}

    %{
      key: key,
      scope: scope,
      agent: agent,
      capability: capability,
      production: production,
      source: source,
      span: %EdgeClassificationSpanV1{
        from_sequence: 1,
        through_sequence: 1,
        classification: classification
      },
      slot: %SweepLeaseSlotV1{
        execution_id: execution,
        plan_header: %ScheduledPlanHeaderV1{
          execution_plan_id: plan_id,
          execution_plan_sha256: digest(0x37)
        },
        source_authorizations: if(source, do: [source], else: [])
      }
    }
  end

  defp source(production, key) do
    claims =
      struct!(
        EdgeSourceClaimsV1,
        production
        |> Map.take([
          :network_scope_id,
          :producer_assignment_id,
          :run_id,
          :run_shard,
          :authority_epoch,
          :origin_principal_id,
          :producer_instance_id,
          :traffic_class,
          :route_profile,
          :origin_kind
        ])
        |> Map.merge(%{
          kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
          context_id: uuid(),
          scope_id: uuid(),
          scope_sha256: digest(0x36),
          target_range_sha256: digest(0x36),
          execution_plan_sha256: digest(0x37),
          collection_not_before_unix_nano: 1,
          collection_expires_unix_nano: 100
        })
      )

    %EdgeSourceAuthorizationV1{
      kind: claims.kind,
      context_id: claims.context_id,
      scope_id: claims.scope_id,
      scope_sha256: claims.scope_sha256,
      capability: sign(:source, claims, key)
    }
  end

  defp sign(purpose, claims, key),
    do:
      IssuerKey.sign(
        %EdgeSignedCapabilityV1{
          not_before_unix_nano: 1,
          expires_at_unix_nano: 100,
          claims: {purpose, claims}
        },
        key
      )

  defp uuid, do: Ecto.UUID.dump!(Ecto.UUID.generate())
  defp digest(n), do: :binary.copy(<<n>>, 32)
end
