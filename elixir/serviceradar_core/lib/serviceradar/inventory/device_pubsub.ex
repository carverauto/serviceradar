defmodule ServiceRadar.Inventory.DevicePubSub do
  @moduledoc """
  PubSub broadcaster for inventory device lifecycle events.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:inventory:devices"
  @invalidation_topic "serviceradar:inventory:device_invalidations"

  @doc """
  Returns the devices topic.
  """
  def topic, do: @topic

  @doc "Topic for bounded dirty-identity hints, including committed bulk writes."
  def invalidation_topic, do: @invalidation_topic

  @doc "Broadcasts committed identities; consumers reread current state instead of trusting event order."
  def broadcast_invalidated(ids) do
    {selected, rescan?} = bounded_hints(ids)

    selected
    |> Enum.reverse()
    |> Enum.chunk_every(500)
    |> Enum.each(&safe_broadcast(@invalidation_topic, {:devices_invalidated, Enum.uniq(&1)}))

    if rescan?, do: safe_broadcast(@invalidation_topic, :devices_rescan)
    :ok
  end

  # A large ingestion must not put the entire inventory into every subscriber's
  # mailbox. A small rescan hint repairs the omitted suffix through paged reads.
  defp bounded_hints(ids) do
    ids
    |> Enum.reduce_while({[], 0, 0, false}, fn
      id, {acc, count, bytes, _rescan?} when is_binary(id) and id != "" ->
        if count < 5_000 and bytes + byte_size(id) <= 524_288 do
          {:cont, {[id | acc], count + 1, bytes + byte_size(id), false}}
        else
          {:halt, {acc, count, bytes, true}}
        end

      _invalid, acc ->
        {:cont, acc}
    end)
    |> then(fn {ids, _count, _bytes, rescan?} -> {ids, rescan?} end)
  end

  @doc """
  Subscribe to device lifecycle updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Broadcast that a device was created.
  """
  def broadcast_created(%{uid: uid} = device) when is_binary(uid) do
    safe_broadcast(@topic, {:device_created, uid, device})
    broadcast_invalidated([uid])
  end

  def broadcast_created(_), do: :ok

  @doc """
  Broadcast that a device was updated.
  """
  def broadcast_updated(%{uid: uid} = device) when is_binary(uid) do
    safe_broadcast(@topic, {:device_updated, uid, device})
    broadcast_invalidated([uid])
  end

  def broadcast_updated(_), do: :ok

  @doc """
  Broadcast that a device was deleted.
  """
  def broadcast_deleted(%{uid: uid}) when is_binary(uid) do
    safe_broadcast(@topic, {:device_deleted, uid})
    broadcast_invalidated([uid])
  end

  def broadcast_deleted(_), do: :ok

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
