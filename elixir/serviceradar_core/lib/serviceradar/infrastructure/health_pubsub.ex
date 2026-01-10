defmodule ServiceRadar.Infrastructure.HealthPubSub do
  @moduledoc """
  PubSub broadcaster for internal health state events.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:health_events:<tenant_id>` - Health event updates for a tenant

  ## Events

  - `{:health_event, %ServiceRadar.Infrastructure.HealthEvent{}}`
  """

  @pubsub ServiceRadar.PubSub

  @doc """
  Build the per-tenant health events topic.
  """
  def topic(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    "serviceradar:health_events:#{tenant_id}"
  end

  def topic(_), do: nil

  @doc """
  Broadcast a HealthEvent to the per-tenant topic.
  """
  def broadcast_health_event(event) do
    case topic(Map.get(event, :tenant_id)) do
      nil -> :ok
      topic -> safe_broadcast(topic, {:health_event, event})
    end
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
