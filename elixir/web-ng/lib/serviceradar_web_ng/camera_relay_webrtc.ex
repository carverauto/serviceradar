defmodule ServiceRadarWebNG.CameraRelayWebRTC do
  @moduledoc """
  Browser-facing WebRTC signaling metadata and delegation for camera relays.
  """

  alias ServiceRadar.WebRTC.IceCredentials
  alias ServiceRadarWebNG.CameraRelayWebRTCSignalingManager

  @webrtc_transport "membrane_webrtc"

  def transport_name, do: @webrtc_transport

  def enabled? do
    Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled, false)
  end

  def metadata(%{id: relay_session_id}) when is_binary(relay_session_id), do: metadata(relay_session_id)

  def metadata(relay_session_id) when is_binary(relay_session_id) do
    %{
      webrtc_enabled: enabled?(),
      webrtc_playback_transport: if(enabled?(), do: @webrtc_transport),
      webrtc_signaling_path: if(enabled?(), do: signaling_path(relay_session_id)),
      webrtc_ice_servers: if(enabled?(), do: ice_servers(), else: [])
    }
  end

  def metadata(_other) do
    %{
      webrtc_enabled: enabled?(),
      webrtc_playback_transport: if(enabled?(), do: @webrtc_transport),
      webrtc_signaling_path: nil,
      webrtc_ice_servers: if(enabled?(), do: ice_servers(), else: [])
    }
  end

  def signaling_path(relay_session_id) when is_binary(relay_session_id) do
    "/api/camera-relay-sessions/#{relay_session_id}/webrtc/session"
  end

  @doc """
  Creates a WebRTC viewer session for a relay session.

  core-elx gets only the static (credential-free) ICE servers and mints its
  own peer credentials. Once core-elx has assigned the viewer session id,
  the browser's ICE servers are minted for exactly that viewer and returned
  with the signaling response (`ice_servers`, `ice_credentials`), never in
  page assigns.
  """
  def create_session(relay_session_id, opts) when is_binary(relay_session_id) do
    if enabled?() do
      static_servers = ice_servers()

      case manager().create_session(relay_session_id, Keyword.put_new(opts, :ice_servers, static_servers)) do
        {:ok, %{viewer_session_id: viewer_session_id} = signal_session} when is_binary(viewer_session_id) ->
          browser_ice =
            IceCredentials.peer_ice_servers(
              {"camera_relay", relay_session_id, viewer_session_id},
              static_servers,
              actor_id: actor_id(Keyword.get(opts, :scope)),
              session_id: relay_session_id
            )

          {:ok, Map.merge(signal_session, browser_ice)}

        other ->
          other
      end
    else
      {:error, "camera relay webrtc playback is unavailable"}
    end
  end

  def submit_answer(relay_session_id, viewer_session_id, answer_sdp, opts)
      when is_binary(relay_session_id) and is_binary(viewer_session_id) and is_binary(answer_sdp) do
    if enabled?() do
      manager().submit_answer(relay_session_id, viewer_session_id, answer_sdp, opts)
    else
      {:error, "camera relay webrtc playback is unavailable"}
    end
  end

  def add_ice_candidate(relay_session_id, viewer_session_id, candidate, opts)
      when is_binary(relay_session_id) and is_binary(viewer_session_id) do
    if enabled?() do
      manager().add_ice_candidate(relay_session_id, viewer_session_id, candidate, opts)
    else
      {:error, "camera relay webrtc playback is unavailable"}
    end
  end

  def close_session(relay_session_id, viewer_session_id, opts)
      when is_binary(relay_session_id) and is_binary(viewer_session_id) do
    if enabled?() do
      manager().close_session(relay_session_id, viewer_session_id, opts)
    else
      {:error, "camera relay webrtc playback is unavailable"}
    end
  end

  def ice_servers do
    :serviceradar_web_ng
    |> Application.get_env(:camera_relay_webrtc_ice_servers, [])
    |> Enum.map(&normalize_ice_server/1)
    |> Enum.reject(&is_nil/1)
  end

  defp actor_id(%{user: %{id: id}}) when not is_nil(id), do: to_string(id)
  defp actor_id(_scope), do: nil

  defp manager do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_signaling_manager,
      CameraRelayWebRTCSignalingManager
    )
  end

  defp normalize_ice_server(url) when is_binary(url) do
    trimmed = String.trim(url)
    if trimmed == "", do: nil, else: %{urls: [trimmed]}
  end

  defp normalize_ice_server(%{} = server) do
    urls =
      case Map.get(server, :urls) || Map.get(server, "urls") do
        values when is_list(values) ->
          values
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        value when is_binary(value) ->
          value
          |> String.trim()
          |> case do
            "" -> []
            trimmed -> [trimmed]
          end

        _other ->
          []
      end

    if urls == [] do
      nil
    else
      %{
        urls: urls,
        username: optional_string(Map.get(server, :username) || Map.get(server, "username")),
        credential: optional_string(Map.get(server, :credential) || Map.get(server, "credential"))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp normalize_ice_server(_other), do: nil

  defp optional_string(nil), do: nil

  defp optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
