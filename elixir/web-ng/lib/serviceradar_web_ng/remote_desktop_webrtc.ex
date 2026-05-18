defmodule ServiceRadarWebNG.RemoteDesktopWebRTC do
  @moduledoc """
  Browser-facing WebRTC signaling metadata and delegation for desktop remote access.
  """

  alias ServiceRadarWebNG.RemoteDesktopWebRTCSignalingManager

  require Logger

  @webrtc_transport "webrtc_desktop_media"
  @turn_credential_warning_key {__MODULE__, :turn_static_credential_warning_emitted}
  @default_turn_credential_ttl_seconds 3_600
  @max_turn_credential_ttl_seconds 3_600

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
      desktop_webrtc_ice_servers: if(enabled?(), do: ice_servers(session_id: session_id), else: [])
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
      manager().create_session(
        session_id,
        Keyword.put_new(opts, :ice_servers, ice_servers(Keyword.put(opts, :session_id, session_id)))
      )
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

  def ice_servers(opts \\ []) do
    :serviceradar_web_ng
    |> Application.get_env(:remote_access_desktop_webrtc_ice_servers, [])
    |> Enum.map(&normalize_ice_server/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&mint_turn_credentials(&1, opts))
    |> tap(&warn_on_unfresh_turn_credentials/1)
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
        credential: optional_string(Map.get(server, :credential) || Map.get(server, "credential")),
        turn_shared_secret:
          optional_string(
            Map.get(server, :turn_shared_secret) ||
              Map.get(server, "turn_shared_secret") ||
              Map.get(server, :shared_secret) ||
              Map.get(server, "shared_secret")
          )
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

  defp mint_turn_credentials(%{urls: urls} = server, opts) when is_list(urls) do
    if Enum.any?(urls, &turn_url?/1) do
      case turn_shared_secret(server) do
        nil ->
          Map.delete(server, :turn_shared_secret)

        shared_secret ->
          username = "#{turn_credential_expires_at()}:#{turn_credential_subject(opts)}"

          server
          |> Map.delete(:turn_shared_secret)
          |> Map.put(:username, username)
          |> Map.put(:credential, turn_credential(shared_secret, username))
      end
    else
      Map.delete(server, :turn_shared_secret)
    end
  end

  defp mint_turn_credentials(server, _opts), do: Map.delete(server, :turn_shared_secret)

  defp turn_shared_secret(server) do
    server[:turn_shared_secret] ||
      optional_string(Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_turn_shared_secret))
  end

  defp turn_credential_expires_at do
    System.system_time(:second) + turn_credential_ttl_seconds()
  end

  defp turn_credential_ttl_seconds do
    :serviceradar_web_ng
    |> Application.get_env(
      :remote_access_desktop_webrtc_turn_credential_ttl_seconds,
      @default_turn_credential_ttl_seconds
    )
    |> case do
      seconds when is_integer(seconds) and seconds > 0 -> min(seconds, @max_turn_credential_ttl_seconds)
      _other -> @default_turn_credential_ttl_seconds
    end
  end

  defp turn_credential_subject(opts) do
    opts
    |> Keyword.get(:scope)
    |> case do
      %{user: %{id: id}} when not is_nil(id) -> id
      _other -> Keyword.get(opts, :session_id, "desktop")
    end
    |> to_string()
    |> String.replace(":", "_")
  end

  defp turn_credential(shared_secret, username) do
    :hmac
    |> :crypto.mac(:sha, shared_secret, username)
    |> Base.encode64()
  end

  defp warn_on_unfresh_turn_credentials(servers) do
    if Enum.any?(servers, &unfresh_turn_credentials?/1) &&
         :persistent_term.get(@turn_credential_warning_key, false) == false do
      :persistent_term.put(@turn_credential_warning_key, true)

      Logger.warning(
        "Remote desktop WebRTC TURN credentials should be ephemeral; configure time-bound TURN usernames or rotate credentials outside ServiceRadar"
      )
    end
  end

  defp unfresh_turn_credentials?(%{urls: urls} = server) when is_list(urls) do
    Enum.any?(urls, &turn_url?/1) && has_turn_credentials?(server) && not time_bound_turn_username?(server[:username])
  end

  defp unfresh_turn_credentials?(_server), do: false

  defp turn_url?(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.downcase()
    |> then(&(String.starts_with?(&1, "turn:") || String.starts_with?(&1, "turns:")))
  end

  defp turn_url?(_url), do: false

  defp has_turn_credentials?(server) do
    is_binary(server[:username]) && server[:username] != "" && is_binary(server[:credential]) && server[:credential] != ""
  end

  defp time_bound_turn_username?(username) when is_binary(username) do
    case username |> String.split(":", parts: 2) |> List.first() |> Integer.parse() do
      {expires_at_unix, ""} -> expires_at_unix > System.system_time(:second)
      _other -> false
    end
  end

  defp time_bound_turn_username?(_username), do: false
end
