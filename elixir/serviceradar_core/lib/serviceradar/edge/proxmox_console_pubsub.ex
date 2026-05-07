defmodule ServiceRadar.Edge.ProxmoxConsolePubSub do
  @moduledoc """
  PubSub boundary for Proxmox console frames delivered by edge agents.
  """

  @pubsub ServiceRadar.PubSub

  def topic(session_id), do: "proxmox_console:#{session_id}"

  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(session_id))
  end

  def broadcast_frame(session_id, frame) when is_binary(session_id) do
    safe_broadcast(topic(session_id), {:proxmox_console_frame, frame})
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
