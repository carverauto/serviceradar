defmodule ServiceRadarWebNG.RemoteDesktopWebRTC do
  @moduledoc """
  Browser-facing WebRTC signaling metadata and delegation for desktop remote access.
  """

  alias ServiceRadarWebNG.RemoteDesktopWebRTCSignalingManager

  @webrtc_transport "webrtc_desktop_media"
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
      desktop_webrtc_ice_servers: []
    }
  end

  def metadata(_other) do
    %{
      desktop_webrtc_enabled: enabled?(),
      desktop_webrtc_transport: if(enabled?(), do: @webrtc_transport),
      desktop_webrtc_signaling_path: nil,
      desktop_webrtc_ice_servers: []
    }
  end

  def signaling_path(session_id) when is_binary(session_id) do
    "/api/remote-access/sessions/#{session_id}/webrtc/session"
  end

  def create_session(session_id, opts) when is_binary(session_id) do
    if enabled?() do
      with {:ok, actor_id} <- required_actor_id(opts) do
        viewer_session_id = Ecto.UUID.generate()

        binding_opts = [
          actor_id: actor_id,
          session_id: session_id,
          viewer_session_id: viewer_session_id
        ]

        ice_servers = ice_servers(binding_opts)

        manager_opts =
          opts
          |> signaling_opts(actor_id)
          |> Keyword.put(:viewer_session_id, viewer_session_id)
          |> Keyword.put(:ice_servers, ice_servers)

        case manager().create_session(session_id, manager_opts) do
          {:ok, signal_session} when is_map(signal_session) ->
            {:ok, Map.put(signal_session, :ice_servers, ice_servers)}

          other ->
            other
        end
      end
    else
      {:error, "desktop webrtc remote access is unavailable"}
    end
  end

  def submit_answer(session_id, viewer_session_id, answer_sdp, opts)
      when is_binary(session_id) and is_binary(viewer_session_id) and is_binary(answer_sdp) do
    if enabled?() do
      with {:ok, actor_id} <- required_actor_id(opts) do
        manager().submit_answer(
          session_id,
          viewer_session_id,
          answer_sdp,
          signaling_opts(opts, actor_id)
        )
      end
    else
      {:error, "desktop webrtc remote access is unavailable"}
    end
  end

  def add_ice_candidate(session_id, viewer_session_id, candidate, opts)
      when is_binary(session_id) and is_binary(viewer_session_id) do
    if enabled?() do
      with {:ok, actor_id} <- required_actor_id(opts) do
        manager().add_ice_candidate(
          session_id,
          viewer_session_id,
          candidate,
          signaling_opts(opts, actor_id)
        )
      end
    else
      {:error, "desktop webrtc remote access is unavailable"}
    end
  end

  def close_session(session_id, viewer_session_id, opts) when is_binary(session_id) and is_binary(viewer_session_id) do
    if enabled?() do
      with {:ok, actor_id} <- required_actor_id(opts) do
        manager().close_session(
          session_id,
          viewer_session_id,
          signaling_opts(opts, actor_id)
        )
      end
    else
      {:error, "desktop webrtc remote access is unavailable"}
    end
  end

  @doc """
  Closes every viewer owned by the current actor for a remote desktop session.

  Cleanup deliberately remains available when the RDP feature flag is turned
  off so a runtime toggle cannot strand already-admitted media resources.
  """
  def close_all_for_session(session_id, opts) when is_binary(session_id) do
    with {:ok, actor_id} <- required_actor_id(opts) do
      manager().close_all_for_session(session_id, signaling_opts(opts, actor_id))
    end
  end

  def ice_servers(opts \\ []) do
    :serviceradar_web_ng
    |> Application.get_env(:remote_access_desktop_webrtc_ice_servers, [])
    |> Enum.map(&normalize_ice_server/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&mint_turn_credentials(&1, opts))
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
      with shared_secret when is_binary(shared_secret) <- turn_shared_secret(server),
           {:ok, subject} <- turn_credential_subject(opts) do
        username = "#{turn_credential_expires_at()}:#{subject}"

        server
        |> Map.delete(:turn_shared_secret)
        |> Map.put(:username, username)
        |> Map.put(:credential, turn_credential(shared_secret, username))
      else
        _missing_binding_or_secret -> nil
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
    with actor_id when is_binary(actor_id) <- normalized_binding(Keyword.get(opts, :actor_id)),
         session_id when is_binary(session_id) <- normalized_binding(Keyword.get(opts, :session_id)),
         viewer_session_id when is_binary(viewer_session_id) <-
           normalized_binding(Keyword.get(opts, :viewer_session_id)) do
      {:ok, Enum.join([actor_id, session_id, viewer_session_id], ":")}
    else
      _missing_binding -> {:error, :turn_viewer_binding_required}
    end
  end

  defp turn_credential(shared_secret, username) do
    :hmac
    |> :crypto.mac(:sha, shared_secret, username)
    |> Base.encode64()
  end

  defp turn_url?(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.downcase()
    |> then(&(String.starts_with?(&1, "turn:") || String.starts_with?(&1, "turns:")))
  end

  defp turn_url?(_url), do: false

  defp required_actor_id(opts) do
    actor_id =
      Keyword.get(opts, :actor_id) ||
        case Keyword.get(opts, :scope) do
          %{user: %{id: id}} -> id
          _scope -> nil
        end

    case normalized_binding(actor_id) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  defp signaling_opts(opts, actor_id) do
    opts
    |> Keyword.drop([:scope, :ice_servers, :viewer_session_id])
    |> Keyword.put(:actor_id, actor_id)
  end

  defp normalized_binding(nil), do: nil

  defp normalized_binding(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(":", "_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_binding(value) when is_atom(value) or is_integer(value),
    do: value |> to_string() |> normalized_binding()

  defp normalized_binding(_value), do: nil
end
