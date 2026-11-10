defmodule ServiceRadar.Edge.RecoveryControl do
  @moduledoc "Core control-plane entry points for an authenticated agent's recovery."

  alias Monitoring.EdgeRecoveryQuery
  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Edge.RecoveryOperations

  def authorize(agent_id, request),
    do: ServiceRadar.Edge.RecoveryAuthorization.issue(agent_id, request)

  def renew_copies(agent_id, query, items),
    do: ServiceRadar.Edge.RecoveryCopyGrants.issue(agent_id, query, items)

  def register(agent_id, %EdgeRecoveryRegistration{} = request) do
    with {:ok, _} <- RecoveryOperations.register(agent_id, request),
         do: RecoveryOperations.status(request.network_scope_id, agent_id, request.recovery_id)
  end

  def get(agent_id, %EdgeRecoveryQuery{} = request) do
    RecoveryOperations.status(request.network_scope_id, agent_id, request.recovery_id)
  end
end
