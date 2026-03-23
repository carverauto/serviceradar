defmodule ServiceRadar.Camera.RelayPubSub do
  @moduledoc """
  PubSub helpers for camera relay session state and media chunk fan-out.

  This is the shared backend bridge between `core-elx` media ingest and
  browser-facing viewers in `web-ng`.
  """

  @pubsub ServiceRadar.PubSub

  def topic(relay_session_id) when is_binary(relay_session_id) and relay_session_id != "" do
    "camera:relay:#{relay_session_id}"
  end

  def topic(_relay_session_id), do: nil

  def subscribe(relay_session_id) do
    case topic(relay_session_id) do
      nil -> {:error, :invalid_relay_session_id}
      topic -> Phoenix.PubSub.subscribe(@pubsub, topic)
    end
  end

  def broadcast_state(relay_session_id, payload) when is_map(payload) do
    broadcast(relay_session_id, {:camera_relay_state, payload})
  end

  def broadcast_chunk(relay_session_id, payload) when is_map(payload) do
    broadcast(relay_session_id, {:camera_relay_chunk, payload})
  end

  defp broadcast(relay_session_id, event) do
    case {topic(relay_session_id), Process.whereis(@pubsub)} do
      {nil, _pid} ->
        {:error, :invalid_relay_session_id}

      {_topic, nil} ->
        :ok

      {topic, _pid} ->
        Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
