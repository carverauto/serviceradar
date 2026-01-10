defmodule ServiceRadar.Events.PubSub do
  @moduledoc """
  PubSub broadcaster for OCSF event updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:events:<tenant_id>` - OCSF event updates for a tenant

  ## Events

  - `{:ocsf_event, %ServiceRadar.Monitoring.OcsfEvent{}}`
  """

  @pubsub ServiceRadar.PubSub

  @doc """
  Build the per-tenant OCSF events topic.
  """
  def topic(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    "serviceradar:events:#{tenant_id}"
  end

  def topic(_), do: nil

  @doc """
  Broadcast an OCSF event to the per-tenant topic.
  """
  def broadcast_event(%{tenant_id: tenant_id} = event) do
    case topic(tenant_id) do
      nil -> :ok
      topic -> safe_broadcast(topic, {:ocsf_event, event})
    end
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
