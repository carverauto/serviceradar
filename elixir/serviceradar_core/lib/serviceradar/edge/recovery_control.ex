defmodule ServiceRadar.Edge.RecoveryControl do
  @moduledoc "Core control-plane entry points for an authenticated agent's recovery."

  alias Monitoring.EdgeRecoveryQuery
  alias Monitoring.EdgeRecoveryRegistration
  alias Monitoring.EdgeRecoveryStatus
  alias ServiceRadar.Edge.RecoveryOperations

  def register(agent_id, %EdgeRecoveryRegistration{} = request) do
    with {:ok, operation} <- RecoveryOperations.register(agent_id, request),
         do: {:ok, status(operation)}
  end

  def get(agent_id, %EdgeRecoveryQuery{} = request) do
    case RecoveryOperations.fetch(request.network_scope_id, agent_id, request.recovery_id) do
      {:ok, nil} -> {:error, :registration_missing}
      {:ok, operation} -> {:ok, status(operation)}
      error -> error
    end
  end

  defp status(%{blocked_reason: nil}),
    do: %EdgeRecoveryStatus{state: :EDGE_RECOVERY_STATE_PENDING, reason: "consumer_pending"}

  defp status(%{blocked_reason: reason}),
    do: %EdgeRecoveryStatus{state: :EDGE_RECOVERY_STATE_BLOCKED, reason: reason}
end
