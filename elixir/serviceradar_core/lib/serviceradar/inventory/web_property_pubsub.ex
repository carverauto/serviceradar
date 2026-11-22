defmodule ServiceRadar.Inventory.WebPropertyPubSub do
  @moduledoc """
  PubSub broadcaster for L7 web property lifecycle and RUM policy updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:inventory:web_properties"
  @rum_policy_topic "serviceradar:rum:policy_updates"

  @doc "Returns the web properties lifecycle topic."
  def topic, do: @topic

  @doc "Returns the RUM policy update topic (consumed by M4.2 NATS policy sync)."
  def rum_policy_topic, do: @rum_policy_topic

  @doc "Subscribe to web property lifecycle updates."
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc "Subscribe to RUM policy update notifications."
  def subscribe_rum_policy do
    Phoenix.PubSub.subscribe(@pubsub, @rum_policy_topic)
  end

  @doc "Broadcast that a web property was created."
  def broadcast_created(%{id: id} = web_property) when is_binary(id) do
    safe_broadcast(@topic, {:web_property_created, id, web_property})
    broadcast_rum_policy_changed(id, :created, web_property)
  end

  def broadcast_created(_), do: :ok

  @doc "Broadcast that a web property was updated."
  def broadcast_updated(%{id: id} = web_property) when is_binary(id) do
    safe_broadcast(@topic, {:web_property_updated, id, web_property})
    broadcast_rum_policy_changed(id, :updated, web_property)
  end

  def broadcast_updated(_), do: :ok

  @doc "Broadcast that a web property's RUM site key was rotated."
  def broadcast_rum_key_rotated(%{id: id} = web_property) when is_binary(id) do
    safe_broadcast(@topic, {:web_property_updated, id, web_property})
    broadcast_rum_policy_changed(id, :rum_key_rotated, web_property)
  end

  def broadcast_rum_key_rotated(_), do: :ok

  @doc "Broadcast that a web property was deleted."
  def broadcast_deleted(%{id: id} = web_property) when is_binary(id) do
    safe_broadcast(@topic, {:web_property_deleted, id})
    broadcast_rum_policy_changed(id, :deleted, web_property)
  end

  def broadcast_deleted(_), do: :ok

  defp broadcast_rum_policy_changed(id, reason, web_property) do
    safe_broadcast(
      @rum_policy_topic,
      {:web_property_rum_policy_changed, id, reason, web_property}
    )
  end

  defp safe_broadcast(topic, message) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, message)
    end
  end
end
