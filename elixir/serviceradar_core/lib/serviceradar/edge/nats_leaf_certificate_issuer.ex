defmodule ServiceRadar.Edge.NatsLeafCertificateIssuer do
  @moduledoc """
  Issues the two certificates an edge-site NATS leaf server needs, from the
  agent-gateway CA (the same internal CA that issues agent mTLS identities and
  that the hub's NATS `root.pem` trusts):

    * a **leaf client** certificate (`:nats_leaf`) the leaf presents to the hub's
      leafnode listener. It carries the partition role URI SAN
      `spiffe://serviceradar.local/nats-leaf/<partition>`, which the chart's
      `leafnodes { authorization }` block maps to the platform account.
    * a **local server** certificate (`:nats_leaf_server`) for collectors that
      connect to the leaf, with SANs for `localhost`, `127.0.0.1` and the site's
      local NATS host.

  Core never holds the CA key: it asks any live agent-gateway node over ERTS RPC.
  """

  require Logger

  @gateway_cert_issuer ServiceRadarAgentGateway.CertIssuer
  @rpc_timeout 30_000

  @type leaf_material :: %{
          leaf_cert_pem: String.t(),
          leaf_key_pem: String.t(),
          server_cert_pem: String.t(),
          server_key_pem: String.t(),
          ca_chain_pem: String.t()
        }

  @doc """
  Issues leaf client and server certificates for `edge_site`.

  Options:
    * `:partition_id` - deployment partition (default from config/env)
    * `:gateway_node` - skip discovery and use this node
    * `:rpc_call` - injectable `:rpc.call/5` (tests)
    * `:nodes` - injectable node list for discovery (tests)
  """
  @spec issue(map(), keyword()) :: {:ok, leaf_material()} | {:error, term()}
  def issue(edge_site, opts \\ []) do
    partition_id = Keyword.get_lazy(opts, :partition_id, &partition_id/0)
    slug = Map.fetch!(edge_site, :slug)

    with {:ok, node} <- gateway_node(opts),
         {:ok, client} <- rpc_issue(node, "leaf-#{slug}", partition_id, :nats_leaf, [], opts),
         {:ok, server} <-
           rpc_issue(
             node,
             "leaf-#{slug}-server",
             partition_id,
             :nats_leaf_server,
             [server_hosts: local_hosts(edge_site)],
             opts
           ) do
      {:ok,
       %{
         leaf_cert_pem: client.certificate_pem,
         leaf_key_pem: client.private_key_pem,
         server_cert_pem: server.certificate_pem,
         server_key_pem: server.private_key_pem,
         ca_chain_pem: client.ca_chain_pem
       }}
    end
  end

  @doc "The deployment partition leaf identities are issued in."
  @spec partition_id() :: String.t()
  def partition_id do
    Application.get_env(:serviceradar, :nats_leaf_partition_id) ||
      System.get_env("SERVICERADAR_OTX_PARTITION") || "default"
  end

  @doc false
  @spec local_hosts(map()) :: [String.t()]
  def local_hosts(edge_site) do
    case Map.get(edge_site, :nats_leaf_url) do
      url when is_binary(url) and url != "" ->
        case URI.parse(url) do
          %URI{host: host} when is_binary(host) and host != "" -> [host]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp rpc_issue(node, component_id, partition_id, component_type, extra_opts, opts) do
    rpc_call = Keyword.get(opts, :rpc_call, &:rpc.call/5)

    issuer_opts =
      Keyword.merge(
        [audit_actor: %{id: "system", email: "nats-leaf-provisioner@serviceradar.local"}],
        extra_opts
      )

    case rpc_call.(
           node,
           @gateway_cert_issuer,
           :issue_agent_bundle,
           [component_id, partition_id, component_type, issuer_opts],
           @rpc_timeout
         ) do
      {:ok, %{certificate_pem: _, private_key_pem: _, ca_chain_pem: _} = bundle} ->
        {:ok, bundle}

      {:error, reason} ->
        {:error, {:leaf_certificate_issue_failed, reason}}

      {:badrpc, reason} ->
        Logger.warning("[NatsLeafCertificateIssuer] gateway RPC failed: #{inspect(reason)}")
        {:error, :gateway_unavailable}

      other ->
        {:error, {:leaf_certificate_issue_failed, other}}
    end
  end

  defp gateway_node(opts) do
    case Keyword.get(opts, :gateway_node) do
      node when is_atom(node) and not is_nil(node) -> {:ok, node}
      _ -> discover_gateway_node(opts)
    end
  end

  # GatewayTracker lives on core nodes; ask each connected node for an active
  # gateway and take the first one that reports a node.
  defp discover_gateway_node(opts) do
    rpc_call = Keyword.get(opts, :rpc_call, &:rpc.call/5)
    nodes = Keyword.get_lazy(opts, :nodes, fn -> [Node.self() | Node.list()] end)

    Enum.find_value(nodes, {:error, :gateway_unavailable}, fn node ->
      case rpc_call.(node, ServiceRadar.GatewayTracker, :list_gateways, [], 2_000) do
        gateways when is_list(gateways) ->
          Enum.find_value(gateways, fn
            %{active: true, node: gateway_node} when is_atom(gateway_node) -> {:ok, gateway_node}
            _ -> nil
          end)

        _ ->
          nil
      end
    end)
  end
end
