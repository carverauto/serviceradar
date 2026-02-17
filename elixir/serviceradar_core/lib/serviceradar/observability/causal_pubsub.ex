defmodule ServiceRadar.Observability.CausalPubSub do
  @moduledoc """
  PubSub broadcaster for normalized causal signal updates.

  These updates are produced by the EventWriter causal signal processor for
  external BMP/SIEM events and can be consumed by topology overlay readers.
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:causal_signals"

  @doc """
  Returns the causal signal topic.
  """
  def topic, do: @topic

  @doc """
  Broadcast a causal signal ingestion event.
  """
  def broadcast_ingest(event) when is_map(event) do
    safe_broadcast(@topic, {:causal_signal_ingested, event})
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
