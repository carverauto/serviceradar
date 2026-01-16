defmodule ServiceRadar.AgentConfig.ConfigPublisher do
  @moduledoc """
  Publishes config change events to NATS for cache invalidation.

  When Ash resources that affect agent configs change, this module publishes
  events to NATS so that other nodes (gateways, other core instances) can
  invalidate their caches.

  Each tenant instance publishes to its own NATS, providing implicit tenant isolation
  without needing tenant_id in the API or NATS subjects.

  ## Event Format

  Events are published to: `serviceradar.config.invalidated.{config_type}`

  Payload:
  ```json
  {
    "config_type": "sweep",
    "partition": "default",       // optional
    "agent_id": "agent-123",      // optional
    "source_resource": "SweepGroup",
    "source_id": "uuid",
    "action": "updated",
    "timestamp": "2024-01-01T00:00:00Z"
  }
  ```
  """

  require Logger

  alias ServiceRadar.AgentConfig.ConfigServer

  @subject_prefix "serviceradar.config.invalidated"

  @doc """
  Publishes a config invalidation event.

  This will invalidate local cache and publish to NATS for cluster-wide invalidation.
  """
  @spec publish_invalidation(atom(), keyword()) :: :ok | {:error, term()}
  def publish_invalidation(config_type, opts \\ []) do
    # Invalidate local cache immediately
    ConfigServer.invalidate(config_type)

    # Build and publish NATS event
    payload = build_payload(config_type, opts)
    subject = build_subject(config_type)

    case publish_to_nats(subject, payload) do
      :ok ->
        Logger.debug("ConfigPublisher: published invalidation for type=#{config_type}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "ConfigPublisher: failed to publish invalidation: #{inspect(reason)}"
        )

        # Still return :ok since local cache was invalidated
        :ok
    end
  end

  @doc """
  Publishes an invalidation event for a specific resource change.
  """
  @spec publish_resource_change(atom(), module(), String.t(), atom()) ::
          :ok | {:error, term()}
  def publish_resource_change(config_type, resource_module, resource_id, action) do
    opts = [
      source_resource: resource_module |> Module.split() |> List.last(),
      source_id: resource_id,
      action: action
    ]

    publish_invalidation(config_type, opts)
  end

  # Note: subscribe functionality will be added when NATS subscription handler is implemented

  # Private helpers

  defp build_subject(config_type) do
    "#{@subject_prefix}.#{config_type}"
  end

  defp build_payload(config_type, opts) do
    %{
      config_type: to_string(config_type),
      partition: Keyword.get(opts, :partition),
      agent_id: Keyword.get(opts, :agent_id),
      source_resource: Keyword.get(opts, :source_resource),
      source_id: Keyword.get(opts, :source_id),
      action: Keyword.get(opts, :action) |> to_string_or_nil(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(atom) when is_atom(atom), do: to_string(atom)
  defp to_string_or_nil(other), do: other

  defp publish_to_nats(subject, payload) do
    case Jason.encode(payload) do
      {:ok, json} ->
        ServiceRadar.NATS.Connection.publish(subject, json)

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  rescue
    e ->
      # NATS connection might not be available
      {:error, e}
  end
end
