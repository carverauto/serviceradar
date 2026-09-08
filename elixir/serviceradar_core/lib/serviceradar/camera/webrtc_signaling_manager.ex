defmodule ServiceRadar.Camera.WebRTCSignalingManager do
  @moduledoc """
  Default relay-scoped WebRTC signaling contract.

  The initial implementation intentionally returns an unavailable result until
  core-elx-backed WebRTC negotiation is wired in.
  """

  def create_session(_relay_session_id, _opts),
    do: {:error, "camera relay webrtc signaling unavailable"}

  def submit_answer(_relay_session_id, _viewer_session_id, _answer_sdp, _opts),
    do: {:error, "camera relay webrtc signaling unavailable"}

  def add_ice_candidate(_relay_session_id, _viewer_session_id, _candidate, _opts),
    do: {:error, "camera relay webrtc signaling unavailable"}
end
