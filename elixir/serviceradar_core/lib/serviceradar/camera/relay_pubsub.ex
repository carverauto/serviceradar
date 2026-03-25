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

  def viewer_control_topic, do: "camera:relay:viewers"

  def subscribe_viewer_control do
    Phoenix.PubSub.subscribe(@pubsub, viewer_control_topic())
  end

  def viewer_topic(relay_session_id, viewer_id)
      when is_binary(relay_session_id) and relay_session_id != "" and is_binary(viewer_id) and
             viewer_id != "" do
    "camera:relay:#{relay_session_id}:viewer:#{viewer_id}"
  end

  def viewer_topic(_relay_session_id, _viewer_id), do: nil

  def subscribe_viewer(relay_session_id, viewer_id) do
    case viewer_topic(relay_session_id, viewer_id) do
      nil -> {:error, :invalid_viewer_topic}
      topic -> Phoenix.PubSub.subscribe(@pubsub, topic)
    end
  end

  def broadcast_state(relay_session_id, payload) when is_map(payload) do
    broadcast(relay_session_id, {:camera_relay_state, payload})
  end

  def broadcast_chunk(relay_session_id, payload) when is_map(payload) do
    broadcast(relay_session_id, {:camera_relay_chunk, payload})
  end

  def viewer_join(relay_session_id, viewer_id, payload \\ %{}) when is_map(payload) do
    broadcast_control(
      {:camera_relay_viewer_join,
       Map.merge(payload, %{relay_session_id: relay_session_id, viewer_id: viewer_id})}
    )
  end

  def viewer_leave(relay_session_id, viewer_id, payload \\ %{}) when is_map(payload) do
    broadcast_control(
      {:camera_relay_viewer_leave,
       Map.merge(payload, %{relay_session_id: relay_session_id, viewer_id: viewer_id})}
    )
  end

  def broadcast_viewer_chunk(relay_session_id, viewer_id, payload) when is_map(payload) do
    case {viewer_topic(relay_session_id, viewer_id), Process.whereis(@pubsub)} do
      {nil, _pid} ->
        {:error, :invalid_viewer_topic}

      {_topic, nil} ->
        :ok

      {topic, _pid} ->
        Phoenix.PubSub.broadcast(@pubsub, topic, {:camera_relay_viewer_chunk, payload})
    end
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

  defp broadcast_control(event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, viewer_control_topic(), event)
    end
  end
end
