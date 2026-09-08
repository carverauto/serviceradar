defmodule ServiceRadarWebNG.RemoteDesktopWebRTCTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.RemoteDesktopWebRTC

  @moduletag :db_free

  defmodule ManagerStub do
    @moduledoc false

    def create_session(session_id, opts) do
      send(Application.fetch_env!(:serviceradar_web_ng, :remote_desktop_webrtc_unit_test_pid), {
        :create_session,
        session_id,
        opts
      })

      {:ok,
       %{
         viewer_session_id: Keyword.fetch!(opts, :viewer_session_id),
         signaling_state: "offer_created",
         offer_sdp: "v=0\r\n..."
       }}
    end

    def close_all_for_session(session_id, opts) do
      send(Application.fetch_env!(:serviceradar_web_ng, :remote_desktop_webrtc_unit_test_pid), {
        :close_all_for_session,
        session_id,
        opts
      })

      {:ok, %{closed_viewer_count: 2}}
    end
  end

  setup do
    keys = [
      :remote_access_desktop_rdp_enabled,
      :remote_access_desktop_webrtc_ice_servers,
      :remote_access_desktop_webrtc_turn_shared_secret,
      :remote_access_desktop_webrtc_turn_credential_ttl_seconds,
      :remote_access_desktop_webrtc_signaling_manager,
      :remote_desktop_webrtc_unit_test_pid
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:serviceradar_web_ng, &1)})

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_webrtc_signaling_manager,
      ManagerStub
    )

    Application.put_env(:serviceradar_web_ng, :remote_desktop_webrtc_unit_test_pid, self())

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    :ok
  end

  test "ordinary session metadata never exposes TURN credentials" do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers, [
      %{
        urls: ["turn:turn.example.com:3478"],
        turn_shared_secret: "turn-rest-secret"
      }
    ])

    metadata = RemoteDesktopWebRTC.metadata("session-1")

    assert metadata.desktop_webrtc_enabled
    assert metadata.desktop_webrtc_ice_servers == []
  end

  test "drops static and incompletely bound TURN credentials" do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers, [
      %{
        urls: ["turn:turn.example.com:3478"],
        username: "static-user",
        credential: "static-password"
      }
    ])

    assert RemoteDesktopWebRTC.ice_servers() == []

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_turn_shared_secret, "global-secret")

    assert RemoteDesktopWebRTC.ice_servers(actor_id: "actor-1", session_id: "session-1") == []
  end

  test "mints TURN credentials bound to the exact actor, session, and viewer" do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_turn_credential_ttl_seconds, 90)

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers, [
      %{
        urls: ["turn:turn.example.com:3478"],
        turn_shared_secret: "turn-rest-secret",
        username: "static-user",
        credential: "static-password"
      }
    ])

    now = System.system_time(:second)

    assert [%{username: username, credential: credential} = server] =
             RemoteDesktopWebRTC.ice_servers(
               actor_id: "actor-1",
               session_id: "session-1",
               viewer_session_id: "viewer-1"
             )

    assert server.urls == ["turn:turn.example.com:3478"]
    refute Map.has_key?(server, :turn_shared_secret)
    refute credential == "static-password"
    assert [expires_at, "actor-1", "session-1", "viewer-1"] = String.split(username, ":")
    assert {expires_at, ""} = Integer.parse(expires_at)
    assert expires_at >= now + 85
    assert expires_at <= now + 90
    assert credential == expected_turn_credential("turn-rest-secret", username)
  end

  test "creates a unique viewer before minting TURN credentials and passes no raw scope" do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_turn_shared_secret, "global-secret")

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers, [
      %{urls: ["turns:turn.example.com:5349"]}
    ])

    scope = %{user: %{id: "actor-1", email: "actor@example.com"}}

    assert {:ok, first} = RemoteDesktopWebRTC.create_session("session-1", scope: scope)
    assert_receive {:create_session, "session-1", first_opts}

    assert {:ok, second} = RemoteDesktopWebRTC.create_session("session-1", scope: scope)
    assert_receive {:create_session, "session-1", second_opts}

    assert first.viewer_session_id == first_opts[:viewer_session_id]
    assert second.viewer_session_id == second_opts[:viewer_session_id]
    refute first.viewer_session_id == second.viewer_session_id
    assert first_opts[:actor_id] == "actor-1"
    refute Keyword.has_key?(first_opts, :scope)

    assert [%{username: first_username, credential: first_credential}] = first.ice_servers
    assert [%{username: second_username, credential: second_credential}] = second.ice_servers
    assert String.ends_with?(first_username, ":actor-1:session-1:#{first.viewer_session_id}")
    assert String.ends_with?(second_username, ":actor-1:session-1:#{second.viewer_session_id}")
    refute first_username == second_username
    refute first_credential == second_credential
  end

  test "caps fully bound TURN credential TTL to one hour" do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_turn_shared_secret, "global-secret")
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_turn_credential_ttl_seconds, 86_400)

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers, [
      %{urls: ["turns:turn.example.com:5349"]}
    ])

    now = System.system_time(:second)

    assert [%{username: username}] =
             RemoteDesktopWebRTC.ice_servers(
               actor_id: "actor-2",
               session_id: "session-2",
               viewer_session_id: "viewer-2"
             )

    assert [expires_at | _bindings] = String.split(username, ":")
    assert {expires_at, ""} = Integer.parse(expires_at)
    assert expires_at <= now + 3_600
  end

  test "owner cleanup closes all viewers without forwarding the raw scope or requiring the feature flag" do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false)
    scope = %{user: %{id: "actor-1", email: "actor@example.com"}}

    assert {:ok, %{closed_viewer_count: 2}} =
             RemoteDesktopWebRTC.close_all_for_session("session-1",
               scope: scope,
               reason: "browser_disconnected"
             )

    assert_receive {:close_all_for_session, "session-1", opts}
    assert opts[:actor_id] == "actor-1"
    assert opts[:reason] == "browser_disconnected"
    refute Keyword.has_key?(opts, :scope)
  end

  test "owner cleanup fails closed without an actor binding" do
    assert {:error, :not_found} = RemoteDesktopWebRTC.close_all_for_session("session-1", [])
    refute_receive {:close_all_for_session, _session_id, _opts}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp expected_turn_credential(shared_secret, username) do
    :hmac
    |> :crypto.mac(:sha, shared_secret, username)
    |> Base.encode64()
  end
end
