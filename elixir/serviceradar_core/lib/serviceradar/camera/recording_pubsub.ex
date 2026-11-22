defmodule ServiceRadar.Camera.RecordingPubSub do
  @moduledoc """
  PubSub helpers for per-camera recording timeline updates.

  Broadcasts lightweight `{:camera_recording_updated, %{camera_source_id: id, reason: reason}}`
  notifications on `ServiceRadar.PubSub` whenever a recording block is cataloged or an archive
  state transitions. All broadcasts are best-effort and never fail callers or database
  transactions when PubSub is not started (for example in unit tests).
  """

  @pubsub ServiceRadar.PubSub

  @doc """
  Returns the PubSub topic for a camera's recording timeline updates, or `nil` for invalid IDs.
  """
  @spec topic(term()) :: String.t() | nil
  def topic(camera_source_id) when is_binary(camera_source_id) and camera_source_id != "" do
    "camera:recordings:#{camera_source_id}"
  end

  def topic(_camera_source_id), do: nil

  @doc """
  Subscribes the calling process to recording timeline updates for `camera_source_id`.
  """
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(camera_source_id) do
    case {topic(camera_source_id), Process.whereis(@pubsub)} do
      {nil, _pid} ->
        {:error, :invalid_camera_source_id}

      {_topic, nil} ->
        {:error, :pubsub_unavailable}

      {topic, _pid} ->
        Phoenix.PubSub.subscribe(@pubsub, topic)
    end
  end

  @doc """
  Unsubscribes the calling process from recording timeline updates for `camera_source_id`.
  """
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(camera_source_id) do
    case {topic(camera_source_id), Process.whereis(@pubsub)} do
      {nil, _pid} ->
        :ok

      {_topic, nil} ->
        :ok

      {topic, _pid} ->
        Phoenix.PubSub.unsubscribe(@pubsub, topic)
    end
  end

  @doc """
  Best-effort broadcast of a recording timeline update for `camera_source_id`.
  """
  @spec broadcast_updated(term(), atom()) :: :ok
  def broadcast_updated(camera_source_id, reason) when is_atom(reason) do
    case {topic(camera_source_id), Process.whereis(@pubsub)} do
      {nil, _pid} ->
        :ok

      {_topic, nil} ->
        :ok

      {topic, _pid} ->
        event = {:camera_recording_updated, %{camera_source_id: camera_source_id, reason: reason}}
        safe_broadcast(topic, event)
    end
  end

  def broadcast_updated(_camera_source_id, _reason), do: :ok

  defp safe_broadcast(topic, event) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic, event)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
