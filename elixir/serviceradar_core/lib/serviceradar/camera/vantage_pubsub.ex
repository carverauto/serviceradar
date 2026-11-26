defmodule ServiceRadar.Camera.VantagePubSub do
  @moduledoc """
  Best-effort Phoenix PubSub helpers for per-camera Vantage ML observations.

  Broadcasts `{:camera_vantage_observations, payload}` on
  `"camera:vantage:<camera_source_id>"` without failing callers or transactions
  when `ServiceRadar.PubSub` is not started (e.g. unit tests).
  """

  @pubsub ServiceRadar.PubSub
  @worker_health_topic "camera:vantage:workers"

  @doc "Returns the PubSub topic for a camera's Vantage observations, or `nil`."
  @spec topic(term()) :: String.t() | nil
  def topic(camera_source_id) when is_binary(camera_source_id) and camera_source_id != "" do
    "camera:vantage:#{camera_source_id}"
  end

  def topic(_), do: nil

  @doc "Returns the PubSub topic for Vantage worker health registration updates."
  @spec worker_health_topic() :: String.t()
  def worker_health_topic, do: @worker_health_topic

  @doc "Subscribes the calling process to Vantage worker health registration broadcasts."
  @spec subscribe_worker_health() :: :ok | {:error, term()}
  def subscribe_worker_health do
    case Process.whereis(@pubsub) do
      nil -> {:error, :pubsub_unavailable}
      _pid -> Phoenix.PubSub.subscribe(@pubsub, @worker_health_topic)
    end
  end

  @doc "Unsubscribes the calling process from Vantage worker health registration broadcasts."
  @spec unsubscribe_worker_health() :: :ok
  def unsubscribe_worker_health do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.unsubscribe(@pubsub, @worker_health_topic)
    end
  end

  @doc "Best-effort broadcast of updated Vantage worker registration state."
  @spec broadcast_worker_health(map()) :: :ok
  def broadcast_worker_health(payload) when is_map(payload) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> safe_broadcast(@worker_health_topic, {:vantage_worker_heartbeat, payload})
    end
  end

  def broadcast_worker_health(_), do: :ok

  @doc "Subscribes the calling process to Vantage observation broadcasts for `camera_source_id`."
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(camera_source_id) do
    case {topic(camera_source_id), Process.whereis(@pubsub)} do
      {nil, _pid} -> {:error, :invalid_camera_source_id}
      {_topic, nil} -> {:error, :pubsub_unavailable}
      {topic, _pid} -> Phoenix.PubSub.subscribe(@pubsub, topic)
    end
  end

  @doc "Unsubscribes the calling process from Vantage observation broadcasts."
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(camera_source_id) do
    case {topic(camera_source_id), Process.whereis(@pubsub)} do
      {nil, _pid} -> :ok
      {_topic, nil} -> :ok
      {topic, _pid} -> Phoenix.PubSub.unsubscribe(@pubsub, topic)
    end
  end

  @doc "Best-effort broadcast of projected Vantage observations for `camera_source_id`."
  @spec broadcast_observations(term(), map()) :: :ok
  def broadcast_observations(camera_source_id, payload) when is_map(payload) do
    case {topic(camera_source_id), Process.whereis(@pubsub)} do
      {nil, _pid} ->
        :ok

      {_topic, nil} ->
        :ok

      {topic, _pid} ->
        safe_broadcast(topic, {:camera_vantage_observations, payload})
    end
  end

  def broadcast_observations(_, _), do: :ok

  defp safe_broadcast(topic, event) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic, event)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
