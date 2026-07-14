defmodule ServiceRadarAgentGateway.TestSupport.DesktopMediaFrameForwarderStub do
  @moduledoc false

  def forward_frame(frame, session) do
    notify({:forward_desktop_media_frame, frame, session})

    Application.get_env(
      :serviceradar_agent_gateway,
      :desktop_media_frame_forwarder_result,
      {:ok, ack_for(frame, session)}
    )
  end

  def close_session(desktop_session_id) do
    notify({:close_desktop_media_ingress, desktop_session_id})

    case Application.get_env(
           :serviceradar_agent_gateway,
           :desktop_media_frame_forwarder_close_result,
           :ok
         ) do
      {:raise, message} -> raise message
      {:exit, reason} -> exit(reason)
      result -> result
    end
  end

  defp ack_for(frame, session) do
    %Desktopmedia.DesktopMediaAck{
      desktop_session_id: frame.desktop_session_id,
      media_session_id: frame.media_session_id,
      media_ingest_id: session.media_ingest_id,
      gateway_id: session.gateway_id,
      last_accepted_sequence: frame.sequence,
      credit_bytes: byte_size(frame.metadata || <<>>) + byte_size(frame.payload || <<>>)
    }
  end

  defp notify(message) do
    case Application.get_env(:serviceradar_agent_gateway, :desktop_media_server_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
