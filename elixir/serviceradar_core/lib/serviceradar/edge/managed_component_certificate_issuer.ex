defmodule ServiceRadar.Edge.ManagedComponentCertificateIssuer do
  @moduledoc "Signs host-generated CSRs using only the component's persisted identity binding."
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.CertificateIssuanceAudit

  @identity_types %{
    "log-collector" => :log_collector,
    "flow-collector" => :flow_collector,
    "bmp-collector" => :bmp_collector,
    "trapd" => :trapd
  }

  def roles("nats-leaf"), do: ["local_server", "upstream_client"]
  def roles(service) when is_map_key(@identity_types, service), do: ["client"]
  def roles(_), do: []

  def issue(operation) do
    with {:ok, %{control_session_pid: session}} <-
           AgentCommandBus.resolve_control_session_evidence(
             operation.partition_id,
             operation.host_agent_id,
             nil
           ) do
      gateway = node(session)

      Enum.reduce_while(roles(operation.service), {:ok, %{}}, fn role, {:ok, bundles} ->
        case issue_role(operation, role, gateway) do
          {:ok, bundle} -> {:cont, {:ok, Map.put(bundles, role, bundle)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp issue_role(operation, role, gateway) do
    {identity_id, identity_type} = identity(operation, role)

    opts = [
      authorized_component_id: identity_id,
      authorized_partition_id: operation.partition_id,
      server_hosts: operation.server_hosts,
      audit_action: :managed_component_certificate_issue,
      audit_actor: %{id: operation.requested_by}
    ]

    case Base.decode64(operation.csrs[role]["csr_der"]) do
      {:ok, csr} ->
        case :rpc.call(
               gateway,
               ServiceRadarAgentGateway.CertIssuer,
               :issue_from_csr,
               [csr, identity_id, operation.partition_id, identity_type, opts],
               30_000
             ) do
          {:ok, bundle} -> {:ok, CertificateIssuanceAudit.publish(bundle)}
          {:badrpc, _} -> {:error, :gateway_unavailable}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_issuer_response}
        end

      _ ->
        {:error, :invalid_csr}
    end
  end

  defp identity(%{service: "nats-leaf"} = operation, "local_server"),
    do: {operation.component_id <> "-server", :nats_leaf_server}

  defp identity(%{service: "nats-leaf"} = operation, "upstream_client"),
    do: {operation.component_id, :nats_leaf}

  defp identity(operation, "client"),
    do: {operation.component_id, Map.fetch!(@identity_types, operation.service)}
end
