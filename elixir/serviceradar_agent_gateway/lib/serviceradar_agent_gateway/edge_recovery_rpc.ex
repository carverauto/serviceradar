defmodule ServiceRadarAgentGateway.EdgeRecoveryRPC do
  @moduledoc """
  The external core RPC boundary shared by authenticated recovery operations.
  Callers own authentication and typed request validation before invoking it.
  """

  alias ServiceRadarAgentGateway.CoreNodeForwarder

  def call(module, function, args, timeout_ms \\ 10_000) do
    case Application.get_env(:serviceradar_agent_gateway, :edge_recovery_control_rpc) do
      nil -> remote(module, function, args, timeout_ms)
      rpc when is_function(rpc, 4) -> rpc.(module, function, args, timeout_ms)
      _ -> {:error, :core_unavailable}
    end
  end

  defp remote(module, function, args, timeout_ms) do
    case CoreNodeForwarder.call_unwrap(
           module,
           function,
           args,
           timeout: timeout_ms,
           badrpc_error: :core_unavailable
         ) do
      {:error, :peer_too_old} -> {:error, :core_unavailable}
      result -> result
    end
  end
end
