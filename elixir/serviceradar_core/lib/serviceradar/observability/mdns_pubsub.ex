defmodule ServiceRadar.Observability.MdnsPubSub do
  @moduledoc """
  PubSub broadcaster for mDNS discovery ingestion updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:mdns_discovery` - mDNS discovery ingestion updates

  ## Events

  - `{:mdns_ingested, %{count: non_neg_integer(), devices_upserted: non_neg_integer()}}`
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:mdns_discovery"

  @doc """
  Returns the mDNS discovery topic.
  """
  def topic, do: @topic

  @doc """
  Broadcast an mDNS ingestion event.
  """
  def broadcast_ingest(%{count: count, devices_upserted: devices_upserted})
      when is_integer(count) and count > 0 and is_integer(devices_upserted) do
    safe_broadcast(@topic, {:mdns_ingested, %{count: count, devices_upserted: devices_upserted}})
  end

  def broadcast_ingest(_), do: :ok

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
