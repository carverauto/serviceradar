defmodule ServiceRadar.Edge.RecoveryCopyGrants do
  @moduledoc """
  Issues delivery-only rollover authority for exact registered copies. The gateway
  supplies historical typed attribution after signature, principal and retained
  registry checks. Core joins its immutable registration and original issuance
  evidence; current assignment rows cannot substitute for that history.
  """

  alias Monitoring.EdgeDeliveryGrantResponse
  alias Monitoring.EdgeDeliveryGrantResult
  alias ServiceRadar.Edge.BoundedList
  alias ServiceRadar.Edge.DeliveryGrants
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.RecoveryAssignments
  alias ServiceRadar.Edge.RecoveryAttribution
  alias ServiceRadar.Edge.RecoveryOperations
  alias Serviceradar.Edge.V1.EdgeDeliveryClaimsV1
  alias Serviceradar.Edge.V1.EdgeDeliveryRolloverV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1

  def issue(agent, query, items) do
    with true <- items != [] and BoundedList.within?(items, DeliveryGrants.max_items()),
         {:ok, current} when not is_nil(current) <-
           RecoveryOperations.fetch(query.network_scope_id, agent, query.recovery_id),
         true <- is_nil(current.blocked_reason) and current.interval_registered,
         {:ok, %{registration: plan}} <- RecoveryOperations.decode_registration(current),
         {:ok, issuer} <- IssuerKey.configured() do
      copies = Map.new(plan.copies, &{&1.prior_sequence, &1})
      now = System.system_time(:nanosecond)

      {:ok,
       %EdgeDeliveryGrantResponse{
         results: Enum.map(items, &result(&1, agent, plan, copies, issuer, now))
       }}
    else
      {:ok, nil} -> {:error, :registration_missing}
      false -> {:error, :recovery_authority_refused}
      {:error, _} = error -> error
    end
  end

  defp result(item, agent, plan, copies, issuer, now) do
    with {:ok, copy} <- Map.fetch(copies, item.prior_sequence),
         true <- copy.new_sequence == item.new_sequence,
         coordinates = coordinates(plan, agent, copy),
         {:ok, binding} <-
           RecoveryAttribution.bind(
             item.attribution,
             coordinates,
             RecoveryAttribution.attribution(item.attribution)
           ),
         true <- binding == copy.attribution_binding_sha256,
         :ok <- original_mapping(plan, agent, item.attribution) do
      %EdgeDeliveryGrantResult{
        sequence: item.new_sequence,
        delivery_capability: sign(plan, copy, issuer, now)
      }
    else
      {:error, reason} when is_atom(reason) -> refused(item, reason)
      _ -> refused(item, :copy_mismatch)
    end
  end

  defp original_mapping(plan, agent, attribution) do
    case RecoveryAssignments.lookup(
           plan.network_scope_id,
           agent,
           RecoveryAttribution.classification(attribution)
         ) do
      {:found, _} -> :ok
      {:not_scheduled, _} -> :ok
      outcome when is_atom(outcome) -> {:error, outcome}
    end
  end

  defp coordinates(plan, agent, copy) do
    %{
      network_scope_id: plan.network_scope_id,
      authenticated_agent_id: agent,
      lane_route_profile: plan.route_profile,
      lane_traffic_class: plan.traffic_class,
      spool_generation_id: plan.new_spool_id,
      sequence: copy.new_sequence,
      event_id: copy.event_id,
      record_sha256: copy.record_sha256
    }
  end

  defp sign(plan, copy, issuer, now) do
    claims = %EdgeDeliveryClaimsV1{
      event_id: copy.event_id,
      record_sha256: copy.record_sha256,
      spool_id: plan.new_spool_id,
      sequence: copy.new_sequence,
      transition:
        {:rollover,
         %EdgeDeliveryRolloverV1{
           recovery_id: plan.recovery_id,
           prior_spool_id: plan.prior_spool_id,
           prior_sequence: copy.prior_sequence
         }}
    }

    IssuerKey.sign(
      %EdgeSignedCapabilityV1{
        not_before_unix_nano: now,
        expires_at_unix_nano: now + DeliveryGrants.ttl_seconds() * 1_000_000_000,
        claims: {:delivery, claims}
      },
      issuer
    )
  end

  defp refused(item, reason),
    do: %EdgeDeliveryGrantResult{sequence: item.new_sequence, refusal: Atom.to_string(reason)}
end
