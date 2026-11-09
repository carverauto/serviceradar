defmodule ServiceRadar.Edge.RecoveryAuthorization do
  @moduledoc "Issues recovery source authority only for registered bytes under a current output grant."

  alias Monitoring.EdgeRecoveryAuthorizationRequest
  alias Monitoring.EdgeRecoveryAuthorizationResponse
  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputContract
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.RecoveryAssignmentEvidence
  alias ServiceRadar.Edge.RecoveryAssignments
  alias ServiceRadar.Edge.RecoveryOperations
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1
  alias ServiceRadar.Edge.WireDecode

  @contract {"serviceradar.edge.recovery_control", 1}

  def issue(agent_id, %EdgeRecoveryAuthorizationRequest{} = request) do
    with %{recovery: query, production_capability: capability} when not is_nil(query) <- request,
         {:ok, current} when not is_nil(current) <-
           RecoveryOperations.fetch(query.network_scope_id, agent_id, query.recovery_id),
         true <- is_nil(current.blocked_reason) and current.interval_registered,
         {:ok, expected} <- RecoveryOperations.decode_registration(current),
         {:ok, payload} <- WireDecode.decode_recovery_control(request.control_payload),
         true <- registered_body?(payload, expected),
         {:ok, {recovery_id, digest}} <- RecoveryValidate.control_body(payload),
         true <- recovery_id == query.recovery_id,
         {:ok, key} <- IssuerKey.configured(),
         {:ok, contract} <- OutputContract.current(@contract),
         {:ok, production} <-
           production(capability, query.network_scope_id, agent_id, contract, key),
         source = source(capability, production, recovery_id, digest, key),
         {:ok, evidence} <-
           RecoveryAssignmentEvidence.recovery_control(capability, source, key.public_key),
         {:ok, :committed} <- RecoveryAssignments.commit_issuance([evidence]) do
      {:ok, %EdgeRecoveryAuthorizationResponse{source_authorization: source}}
    else
      {:ok, nil} -> {:error, :registration_missing}
      false -> {:error, :recovery_authority_refused}
      {:error, _} = error -> error
      _ -> {:error, :recovery_authority_refused}
    end
  end

  defp registered_body?(%{body: {:manifest_page, page}}, expected),
    do: Enum.at(expected.pages, page.page_index) == page

  defp registered_body?(%{body: {:tombstone, tombstone}}, expected),
    do: expected.tombstone == tombstone

  defp registered_body?(_, _), do: false

  defp production(%{claims: {:production, p}} = capability, scope, agent, contract, key) do
    now = System.system_time(:nanosecond)

    with true <- CapabilitySigning.verify(capability, :production, key.public_key),
         true <- capability.not_before_unix_nano <= now and now < capability.expires_at_unix_nano,
         true <- p.origin_principal_id == agent and p.network_scope_id == scope,
         true <- p.origin_kind == :EDGE_ORIGIN_KIND_AGENT,
         true <- p.route_profile == :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1,
         true <- p.traffic_class == :EDGE_RECORD_TRAFFIC_CLASS_BULK,
         true <- Enum.all?(Map.keys(contract), &(Map.get(p, &1) == Map.get(contract, &1))),
         {:ok, assignment} <- Ecto.UUID.cast(p.producer_assignment_id),
         {:ok, scope_id} <- Ecto.UUID.cast(scope),
         :ok <-
           OutputGrants.check_current(
             assignment,
             agent,
             elem(@contract, 0),
             scope_id,
             p.authority_epoch
           ) do
      {:ok, p}
    else
      _ -> {:error, :production_authority_refused}
    end
  end

  defp production(_, _, _, _, _), do: {:error, :production_authority_refused}

  defp source(capability, production, recovery_id, digest, key) do
    joined =
      Map.take(production, [
        :network_scope_id,
        :origin_principal_id,
        :producer_instance_id,
        :producer_assignment_id,
        :run_id,
        :run_shard,
        :authority_epoch,
        :traffic_class,
        :route_profile,
        :origin_kind
      ])

    claims =
      struct!(
        EdgeSourceClaimsV1,
        Map.merge(joined, %{
          kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
          context_id: recovery_id,
          scope_id: recovery_id,
          scope_sha256: digest
        })
      )

    %EdgeSourceAuthorizationV1{
      kind: claims.kind,
      context_id: recovery_id,
      scope_id: recovery_id,
      scope_sha256: digest,
      capability:
        IssuerKey.sign(
          %EdgeSignedCapabilityV1{
            not_before_unix_nano: capability.not_before_unix_nano,
            expires_at_unix_nano: capability.expires_at_unix_nano,
            claims: {:source, claims}
          },
          key
        )
    }
  end
end
