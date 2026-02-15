defmodule ServiceRadar.Software.TftpPubSub do
  @moduledoc """
  PubSub broadcaster for TFTP session updates.

  Broadcasts state transitions and transfer progress so LiveViews
  can update in real time.
  """

  @pubsub ServiceRadar.PubSub

  def topic, do: "software:tftp_sessions"

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, topic())
  end

  def broadcast_session_updated(session) do
    safe_broadcast(topic(), {:tftp_session_updated, %{
      id: session.id,
      status: session.status,
      mode: session.mode,
      agent_id: session.agent_id,
      bytes_transferred: session.bytes_transferred,
      transfer_rate: session.transfer_rate,
      file_size: session.file_size,
      updated_at: DateTime.utc_now()
    }})
  end

  def broadcast_session_progress(session_id, progress) when is_map(progress) do
    safe_broadcast(topic(), {:tftp_session_progress, Map.merge(progress, %{
      session_id: session_id,
      updated_at: DateTime.utc_now()
    })})
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
