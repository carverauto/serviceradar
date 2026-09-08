defmodule ServiceRadar.Observability.AlertPubSub do
  @moduledoc """
  PubSub broadcaster for alert lifecycle updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:alerts` - alert creation updates

  ## Events

  - `{:alert_created, %{id: binary()}}`
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:alerts"

  @doc """
  Returns the alert lifecycle topic.
  """
  def topic, do: @topic

  @doc """
  Broadcast an alert creation event.
  """
  def broadcast_alert_created(%{id: id}) when is_binary(id) and id != "" do
    safe_broadcast(@topic, {:alert_created, %{id: id}})
  end

  def broadcast_alert_created(_), do: :ok

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
