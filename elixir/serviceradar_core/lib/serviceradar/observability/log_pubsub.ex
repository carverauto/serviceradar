defmodule ServiceRadar.Observability.LogPubSub do
  @moduledoc """
  PubSub broadcaster for log ingestion updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:logs` - Log ingestion updates

  ## Events

  - `{:logs_ingested, %{count: non_neg_integer()}}`
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:logs"

  @doc """
  Returns the log ingestion topic.
  """
  def topic, do: @topic

  @doc """
  Broadcast a log ingestion event.
  """
  def broadcast_ingest(%{count: count}) when is_integer(count) and count > 0 do
    safe_broadcast(@topic, {:logs_ingested, %{count: count}})
  end

  def broadcast_ingest(_), do: :ok

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
