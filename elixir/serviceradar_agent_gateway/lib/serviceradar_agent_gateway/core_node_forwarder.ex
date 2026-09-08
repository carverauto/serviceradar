defmodule ServiceRadarAgentGateway.CoreNodeForwarder do
  @moduledoc false

  require Logger

  def resolve_core_node(service_label, resolver) when is_function(resolver, 0) do
    case resolver.() do
      node when is_atom(node) and not is_nil(node) ->
        {:ok, node}

      other ->
        Logger.error(
          "Failed to resolve core node for #{service_label}: #{inspect(other)} (connected=#{inspect(Node.list())})"
        )

        {:error, :core_unavailable}
    end
  end

  def ensure_core_connected(node, connectivity_module) when is_atom(node) do
    case connectivity_module.ping(node) do
      :pong ->
        :ok

      :pang ->
        Logger.error("Failed to establish distributed Erlang connection to core node #{inspect(node)}")
        {:error, :core_unavailable}

      other ->
        Logger.error("Unexpected core connectivity probe result for #{inspect(node)}: #{inspect(other)}")
        {:error, :core_unavailable}
    end
  end

  def ensure_core_connected(node, _connectivity_module) do
    Logger.error("Failed to establish distributed Erlang connection to core node #{inspect(node)}")
    {:error, :core_unavailable}
  end

  def select_core_node(ingress_label) do
    nodes = Node.list()

    nodes
    |> Enum.find(fn node ->
      case :rpc.call(node, Process, :whereis, [ServiceRadar.ClusterHealth], 5_000) do
        pid when is_pid(pid) -> true
        _other -> false
      end
    end)
    |> Kernel.||(Enum.find(nodes, &core_node?/1))
    |> case do
      nil -> raise ArgumentError, "no core-elx node available for #{ingress_label}"
      node -> node
    end
  end

  defp core_node?(node) when is_atom(node) do
    String.starts_with?(Atom.to_string(node), "#{core_node_basename()}@")
  end

  defp core_node?(_node), do: false

  defp core_node_basename do
    System.get_env("CLUSTER_CORE_NODE_BASENAME") ||
      Application.get_env(:serviceradar_agent_gateway, :cluster_core_node_basename, "serviceradar_core")
  end
end
