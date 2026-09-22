defmodule ServiceRadar.Observability.OtelPubSub do
  @moduledoc """
  PubSub broadcaster for OpenTelemetry signal ingestion updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:otel` - OTel trace and metric ingestion updates

  ## Events

  - `{:otel_traces_ingested, %{count: non_neg_integer()}}`
  - `{:otel_metrics_ingested, %{count: non_neg_integer()}}`
  - `{:otel_trace_summaries_refreshed, %{count: non_neg_integer()}}`
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:otel"

  @doc """
  Returns the OTel ingestion topic.
  """
  def topic, do: @topic

  @doc """
  Broadcast an OTel trace ingestion event.
  """
  def broadcast_traces(%{count: count}) when is_integer(count) and count > 0 do
    safe_broadcast(@topic, {:otel_traces_ingested, %{count: count}})
  end

  def broadcast_traces(_), do: :ok

  @doc """
  Broadcast an OTel metric ingestion event.
  """
  def broadcast_metrics(%{count: count}) when is_integer(count) and count > 0 do
    safe_broadcast(@topic, {:otel_metrics_ingested, %{count: count}})
  end

  def broadcast_metrics(_), do: :ok

  @doc """
  Broadcast an OTel trace summary refresh event.

  Fired by `ServiceRadar.Jobs.RefreshTraceSummariesWorker` when a refresh run
  actually changes summary rows, so live tails can follow summary updates
  instead of polling the summaries table on span ingest.
  """
  def broadcast_trace_summaries(%{count: count}) when is_integer(count) and count > 0 do
    safe_broadcast(@topic, {:otel_trace_summaries_refreshed, %{count: count}})
  end

  def broadcast_trace_summaries(_), do: :ok

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
