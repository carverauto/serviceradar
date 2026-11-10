defmodule ServiceRadarAgentGateway.EdgeRecoveryCopyGrants do
  @moduledoc "Authenticates retained typed records before core grants their registered rollover."

  alias Monitoring.EdgeDeliveryGrantResponse
  alias Monitoring.EdgeDeliveryGrantResult
  alias Monitoring.EdgeRecoveryCopyGrantRequest
  alias Monitoring.EdgeRecoveryQuery
  alias ServiceRadar.Edge.BoundedList
  alias ServiceRadar.Edge.RecoveryAttribution
  alias ServiceRadar.Edge.RecoveryControl
  alias ServiceRadarAgentGateway.EdgeContractRegistry
  alias ServiceRadarAgentGateway.EdgeDeliveryGrants
  alias ServiceRadarAgentGateway.EdgeRecordAuthorization
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.EdgeRecoveryRPC

  def renew(
        %EdgeRecoveryCopyGrantRequest{recovery: %EdgeRecoveryQuery{}} = request,
        %{component_type: :agent, component_id: agent} = identity
      ) do
    with :ok <- bounded(request),
         {:ok, snapshot} <- EdgeRecordTrust.snapshot() do
      identity = EdgeRecordTrust.with_network_scopes(snapshot, identity)
      verified = Enum.map(request.records, &verify(&1, request.recovery, identity, snapshot))
      items = for {:verified, item} <- verified, do: item

      with {:ok, issued} <- issue(agent, request.recovery, items) do
        by_sequence = Map.new(issued.results, &{&1.sequence, &1})
        {:ok, %EdgeDeliveryGrantResponse{results: Enum.map(verified, &result(&1, by_sequence))}}
      end
    else
      {:error, :trust_unavailable} -> {:error, :unavailable, "edge record trust is unavailable"}
      error -> error
    end
  end

  def renew(_, _), do: {:error, :invalid_argument, "invalid recovery copy request"}

  defp bounded(request) do
    records = request.records

    valid =
      envelope?(request) and
        records != [] and BoundedList.within?(records, EdgeDeliveryGrants.max_records()) and
        copy_items?(records)

    if valid, do: :ok, else: {:error, :invalid_argument, "invalid recovery copy bounds"}
  end

  defp envelope?(request) do
    query = request.recovery

    request.__unknown_fields__ == [] and query.__unknown_fields__ == [] and
      uuidv7?(query.recovery_id) and byte_size(query.network_scope_id) == 16
  end

  defp copy_items?(records) do
    Enum.all?(records, &(&1.__unknown_fields__ == [] and &1.prior_sequence > 0 and &1.new_sequence > 0)) and
      Enum.reduce(records, 0, &(byte_size(&1.record_bytes) + &2)) <= EdgeDeliveryGrants.max_record_bytes() and
      length(Enum.uniq_by(records, & &1.prior_sequence)) == length(records) and
      length(Enum.uniq_by(records, & &1.new_sequence)) == length(records)
  end

  defp verify(item, query, identity, snapshot) do
    with {:ok, record} <- EdgeRecordAuthorization.grant_subject(item.record_bytes, identity, snapshot),
         true <- record.network_scope_id == query.network_scope_id,
         {:ok, _route} <-
           EdgeContractRegistry.admit(
             record,
             %{
               authenticated_agent_id: identity.component_id,
               route_profile: record.route_profile,
               traffic_class: record.traffic_class
             },
             snapshot.registry
           ),
         {:ok, attribution} <-
           RecoveryAttribution.historical(item.record_bytes, record.output_contract, %{
             # The immutable installed snapshot is pinned for this request.
             trust_policy_epoch: 1,
             trust: &EdgeRecordTrust.resolve_key(snapshot, &1, &2, &3)
           }) do
      {:verified, %{prior_sequence: item.prior_sequence, new_sequence: item.new_sequence, attribution: attribution}}
    else
      _ -> {:refused, item.new_sequence}
    end
  end

  defp issue(_agent, _query, []), do: {:ok, %EdgeDeliveryGrantResponse{}}

  defp issue(agent, query, items) do
    case EdgeRecoveryRPC.call(RecoveryControl, :renew_copies, [agent, query, items]) do
      {:ok, %EdgeDeliveryGrantResponse{} = response} -> {:ok, response}
      {:error, :registration_missing} -> {:error, :not_found, "recovery is not registered"}
      {:error, :recovery_authority_refused} -> {:error, :permission_denied, "recovery authority refused"}
      _ -> {:error, :unavailable, "recovery copy authority is unavailable"}
    end
  end

  defp result({:refused, sequence}, _issued),
    do: %EdgeDeliveryGrantResult{sequence: sequence, refusal: "copy_authority_refused"}

  defp result({:verified, item}, issued),
    do: Map.get(issued, item.new_sequence, %EdgeDeliveryGrantResult{sequence: item.new_sequence, refusal: "not_issued"})

  defp uuidv7?(<<_::48, 7::4, _::12, 2::2, _::62>>), do: true
  defp uuidv7?(_), do: false
end
