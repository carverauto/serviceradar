defmodule ServiceRadarAgentGateway.EdgeRecoveryControl do
  @moduledoc """
  Authenticates recovery control outside the blocked delivery lane. The principal
  comes from the client certificate and scope membership from installed trust;
  neither is inferred from the registered plan. Core persists intent before any
  recovery authority can be returned.
  """

  alias Monitoring.EdgeRecoveryAuthorizationRequest
  alias Monitoring.EdgeRecoveryQuery
  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Edge.RecoveryControl
  alias ServiceRadar.Edge.RecoveryCoverage
  alias ServiceRadar.Edge.RecoveryOperation
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.EdgeRecoveryRPC

  def register(%EdgeRecoveryRegistration{} = request, identity) do
    with :ok <- registration(request),
         {:ok, agent_id} <- authenticated_namespace(request.network_scope_id, identity) do
      core(:register, agent_id, request)
    end
  end

  def get(%EdgeRecoveryQuery{} = request, identity) do
    with :ok <- query(request),
         {:ok, agent_id} <- authenticated_namespace(request.network_scope_id, identity) do
      core(:get, agent_id, request)
    end
  end

  def authorize(%EdgeRecoveryAuthorizationRequest{recovery: %EdgeRecoveryQuery{} = recovery} = request, identity) do
    with true <- request.__unknown_fields__ == [] and byte_size(request.control_payload) <= 256 * 1024,
         :ok <- query(recovery),
         {:ok, agent_id} <- authenticated_namespace(recovery.network_scope_id, identity) do
      core(:authorize, agent_id, request)
    else
      false -> {:error, :invalid_argument, "invalid recovery authorization"}
      error -> error
    end
  end

  def authorize(_, _), do: {:error, :invalid_argument, "invalid recovery authorization"}

  @doc "Read one authenticated source generation before publication; no delivery disposition is issued."
  def coverage(scope, prior_spool, route, traffic, identity) do
    with {:ok, agent_id} <- authenticated_namespace(scope, identity) do
      EdgeRecoveryRPC.call(RecoveryCoverage, :lookup, [scope, agent_id, prior_spool, route, traffic], 5_000)
    end
  end

  defp registration(request) do
    case RecoveryOperation.validate(request) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_argument, "invalid recovery registration"}
    end
  end

  defp query(request) do
    if request.__unknown_fields__ == [] and uuidv7?(request.recovery_id),
      do: :ok,
      else: {:error, :invalid_argument, "invalid recovery query"}
  end

  defp authenticated_namespace(scope, %{component_type: :agent, component_id: agent_id} = identity)
       when is_binary(agent_id) and byte_size(agent_id) in 1..256 do
    with {:ok, snapshot} <- EdgeRecordTrust.snapshot(),
         %{network_scope_ids: %MapSet{} = scopes} <- EdgeRecordTrust.with_network_scopes(snapshot, identity),
         true <- MapSet.member?(scopes, scope) do
      {:ok, agent_id}
    else
      {:error, _} -> {:error, :unavailable, "edge record trust is unavailable"}
      _ -> {:error, :permission_denied, "recovery scope is not bound to the authenticated agent"}
    end
  end

  defp authenticated_namespace(_, _), do: {:error, :permission_denied, "recovery requires an authenticated agent"}

  defp core(function, agent_id, request) do
    case EdgeRecoveryRPC.call(RecoveryControl, function, [agent_id, request]) do
      {:ok, result} ->
        {:ok, result}

      {:error, :registration_missing} ->
        {:error, :not_found, "recovery is not registered"}

      {:error, reason} when reason in [:recovery_authority_refused, :production_authority_refused] ->
        {:error, :permission_denied, "recovery authority refused"}

      _ ->
        {:error, :unavailable, "edge recovery control is unavailable"}
    end
  rescue
    ArgumentError -> {:error, :unavailable, "edge recovery control is unavailable"}
  end

  defp uuidv7?(<<_::48, 7::4, _::12, 2::2, _::62>>), do: true
  defp uuidv7?(_), do: false
end
