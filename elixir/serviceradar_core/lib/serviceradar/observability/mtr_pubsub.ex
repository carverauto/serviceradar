defmodule ServiceRadar.Observability.MtrPubSub do
  @moduledoc """
  PubSub broadcaster for MTR ingestion updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:mtr` - MTR trace ingestion updates

  ## Events

  - `{:mtr_trace_ingested, %{command_id: String.t() | nil, target: String.t(), agent_id: String.t() | nil}}`
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:mtr"

  def topic, do: @topic

  @doc """
  Broadcast an MTR ingestion event.
  """
  def broadcast_ingest(%{} = attrs) do
    event = %{
      command_id: Map.get(attrs, :command_id),
      target: Map.get(attrs, :target),
      agent_id: Map.get(attrs, :agent_id)
    }

    safe_broadcast(@topic, {:mtr_trace_ingested, event})
  end

  def broadcast_ingest(_), do: :ok

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
