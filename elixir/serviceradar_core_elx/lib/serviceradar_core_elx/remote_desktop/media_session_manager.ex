defmodule ServiceRadarCoreElx.RemoteDesktop.MediaSessionManager do
  @moduledoc """
  Placeholder boundary for attaching desktop media sessions to WebRTC signaling.

  The real desktop media implementation will bind an active RDP route to this
  interface. Until then, the default manager fails closed while tests and
  future implementations can inject a concrete media manager.
  """

  def add_webrtc_viewer(_session_id, _viewer_session_id, _signaling, _opts \\ []) do
    {:error, "desktop media plane is not available"}
  end

  def remove_webrtc_viewer(_session_id, _viewer_session_id), do: :ok
end
