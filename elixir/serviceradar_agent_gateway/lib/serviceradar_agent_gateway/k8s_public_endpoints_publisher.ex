defmodule ServiceRadarAgentGateway.K8sPublicEndpointsPublisher do
  @moduledoc """
  Publishes agent-forwarded Kubernetes public endpoint inventory snapshots
  to JetStream (`inventory.k8s.public_endpoints`) for core EventWriter ingest.

  The agent carries the snapshot as a status `message` body (JSON). Gateway
  stamps mTLS-attested agent/partition headers and republishes the inventory
  bytes so co-located NATS collectors and remote agent_spool installs share
  one core processor.
  """

  require Logger

  @app :serviceradar_agent_gateway
  @config_key :k8s_public_endpoints_publisher
  @default_subject "inventory.k8s.public_endpoints"
  @service_types ~w(k8s_public_endpoints)
  # Align with go/pkg/k8sinventory.MaxSpoolPayloadBytes
  @max_payload_bytes 4 * 1024 * 1024

  @type publish_result :: :ok | :not_k8s_public_endpoints | :disabled | {:error, term()}

  @doc """
  Publish status when it is a k8s public endpoints inventory snapshot.

  Returns `:not_k8s_public_endpoints` when the status is unrelated so the
  caller can continue the normal forward path.
  """
  @spec publish(map()) :: publish_result()
  def publish(status) when is_map(status) do
    if k8s_public_endpoints_status?(status) do
      config = config()

      if Keyword.get(config, :enabled, true) do
        do_publish(status, config)
      else
        :disabled
      end
    else
      :not_k8s_public_endpoints
    end
  end

  def publish(_), do: :not_k8s_public_endpoints

  defp config do
    Application.get_env(@app, @config_key, [])
  end

  defp k8s_public_endpoints_status?(status) do
    type = status[:service_type] || status["service_type"]
    type = type && to_string(type)

    type in @service_types
  end

  defp do_publish(status, config) do
    message = status[:message] || status["message"]

    cond do
      not is_binary(message) or message == "" ->
        Logger.warning(
          "AgentGateway: k8s_public_endpoints status missing binary message",
          agent_id: status[:agent_id]
        )

        {:error, :missing_inventory_payload}

      byte_size(message) > @max_payload_bytes ->
        Logger.warning(
          "AgentGateway: k8s_public_endpoints payload too large",
          agent_id: status[:agent_id],
          message_size: byte_size(message)
        )

        {:error, :inventory_payload_too_large}

      true ->
        publish_payload(status, message, config)
    end
  end

  defp publish_payload(status, message, config) do
    connection = Keyword.get(config, :connection, ServiceRadar.NATS.Connection)
    subject = config |> Keyword.get(:subject, @default_subject) |> to_string()
    headers = inventory_headers(status)

    case connection.publish(subject, message, headers: headers) do
      :ok ->
        Logger.debug(
          "AgentGateway: published k8s_public_endpoints snapshot",
          agent_id: status[:agent_id],
          partition: status[:partition],
          subject: subject,
          message_size: byte_size(message)
        )

        :ok

      {:error, reason} = error ->
        Logger.warning(
          "AgentGateway: failed to publish k8s_public_endpoints",
          agent_id: status[:agent_id],
          reason: inspect(reason),
          subject: subject
        )

        error
    end
  end

  defp inventory_headers(status) do
    agent_id = to_string(status[:agent_id] || "")
    partition = to_string(status[:partition] || "default")
    gateway_id = to_string(status[:gateway_id] || "")

    Enum.reject(
      [
        {"Sr-Agent-Id", agent_id},
        {"Sr-Gateway-Id", gateway_id},
        {"Sr-Partition", partition},
        {"Sr-Ingest-Identity", "agent:" <> agent_id},
        {"Sr-Service-Type", "k8s_public_endpoints"}
      ],
      fn {_k, v} -> v in [nil, ""] end
    )
  end
end
