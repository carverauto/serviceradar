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
    node = CoreNodeForwarder.select_core_node("edge recovery")

    case :rpc.call(node, module, function, args, timeout_ms) do
      {:badrpc, _} -> {:error, :core_unavailable}
      result -> result
    end
  rescue
    ArgumentError -> {:error, :core_unavailable}
  end
end
