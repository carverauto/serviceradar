defmodule ServiceRadar.Events.PubSub do
  @moduledoc """
  PubSub broadcaster for OCSF event updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:events` - OCSF event updates
  - `serviceradar:events:rows` - compact summaries of the event rows EventWriter
    just persisted, for live subscribers such as dashboard packages

  ## Events

  - `{:ocsf_event, %ServiceRadar.Monitoring.OcsfEvent{}}`
  - `{:ocsf_event_rows, [summary]}` where each summary is built by
    `event_summary/1`

  A redelivered JetStream batch can repeat a summary; subscribers dedupe on the
  event `"id"`.
  """

  @pubsub ServiceRadar.PubSub
  @events_topic "serviceradar:events"
  @rows_topic "serviceradar:events:rows"

  @summary_fields ~w(
    class_uid category_uid type_uid activity_id activity_name severity_id severity
    message status_id status status_code log_name log_provider
  )a
  @device_fields ~w(uid hostname name ip mac)

  @doc """
  Returns the OCSF events topic.
  """
  def topic, do: @events_topic

  @doc """
  Returns the topic carrying persisted event row summaries.
  """
  def rows_topic, do: @rows_topic

  @doc """
  Broadcast an OCSF event to the events topic.
  """
  def broadcast_event(event) when is_map(event) do
    safe_broadcast(@events_topic, {:ocsf_event, event})
  end

  @doc """
  Broadcast summaries of persisted event rows to `rows_topic/0`.
  """
  def broadcast_event_rows([]), do: :ok

  def broadcast_event_rows(rows) when is_list(rows) do
    safe_broadcast(@rows_topic, {:ocsf_event_rows, Enum.map(rows, &event_summary/1)})
  end

  @doc """
  Builds the compact, string-keyed summary broadcast for one event row.

  Raw data, observables and unmapped fields are left out; subscribers that need
  them read the event by id.
  """
  def event_summary(row) when is_map(row) do
    base = %{
      "id" => to_string(Map.get(row, :id)),
      "time" => format_time(Map.get(row, :time)),
      "device" => device_summary(Map.get(row, :device)),
      "metadata" => map_or_empty(Map.get(row, :metadata))
    }

    Enum.reduce(@summary_fields, base, fn field, acc ->
      Map.put(acc, Atom.to_string(field), Map.get(row, field))
    end)
  end

  defp device_summary(%{} = device) do
    device
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@device_fields)
  end

  defp device_summary(_device), do: %{}

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_value), do: %{}

  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(time) when is_binary(time), do: time
  defp format_time(_time), do: nil

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
