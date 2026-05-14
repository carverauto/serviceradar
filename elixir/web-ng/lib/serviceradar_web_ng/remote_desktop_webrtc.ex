defmodule ServiceRadarWebNG.RemoteDesktopWebRTC do
  @moduledoc """
  Browser-facing WebRTC signaling metadata and delegation for desktop remote access.
  """

  alias ServiceRadarWebNG.RemoteDesktopWebRTCSignalingManager

  @webrtc_transport "webrtc_desktop_media"

  def transport_name, do: @webrtc_transport

  def enabled? do
    Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false) == true
  end

  def metadata(%{id: session_id}) when is_binary(session_id), do: metadata(session_id)

  def metadata(session_id) when is_binary(session_id) do
    %{
      desktop_webrtc_enabled: enabled?(),
      desktop_webrtc_transport: if(enabled?(), do: @webrtc_transport),
      desktop_webrtc_signaling_path: if(enabled?(), do: signaling_path(session_id)),
      desktop_webrtc_ice_servers: if(enabled?(), do: ice_servers(), else: [])
    }
  end

  def metadata(_other) do
    %{
      desktop_webrtc_enabled: enabled?(),
      desktop_webrtc_transport: if(enabled?(), do: @webrtc_transport),
      desktop_webrtc_signaling_path: nil,
      desktop_webrtc_ice_servers: if(enabled?(), do: ice_servers(), else: [])
    }
  end

  def signaling_path(session_id) when is_binary(session_id) do
    "/api/remote-access/sessions/#{session_id}/webrtc/session"
  end

  def create_session(session_id, opts) when is_binary(session_id) do
    if enabled?() do
      manager().create_session(session_id, Keyword.put_new(opts, :ice_servers, ice_servers()))
    else
      {:error, "desktop webrtc remote access is unavailable"}
    end
  end

  def submit_answer(session_id, viewer_session_id, answer_sdp, opts)
      when is_binary(session_id) and is_binary(viewer_session_id) and is_binary(answer_sdp) do
    if enabled?() do
      manager().submit_answer(session_id, viewer_session_id, answer_sdp, opts)
    else
      {:error, "desktop webrtc remote access is unavailable"}
    end
  end

  def add_ice_candidate(session_id, viewer_session_id, candidate, opts)
      when is_binary(session_id) and is_binary(viewer_session_id) do
    if enabled?() do
      manager().add_ice_candidate(session_id, viewer_session_id, candidate, opts)
    else
      {:error, "desktop webrtc remote access is unavailable"}
    end
  end

  def close_session(session_id, viewer_session_id, opts) when is_binary(session_id) and is_binary(viewer_session_id) do
    if enabled?() do
      manager().close_session(session_id, viewer_session_id, opts)
    else
      {:error, "desktop webrtc remote access is unavailable"}
    end
  end

  def ice_servers do
    :serviceradar_web_ng
    |> Application.get_env(:remote_access_desktop_webrtc_ice_servers, [])
    |> Enum.map(&normalize_ice_server/1)
    |> Enum.reject(&is_nil/1)
  end

  defp manager do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_desktop_webrtc_signaling_manager,
      RemoteDesktopWebRTCSignalingManager
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
