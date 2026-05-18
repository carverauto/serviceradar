defmodule ServiceRadarWebNG.RemoteDesktopWebRTCTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadarWebNG.RemoteDesktopWebRTC

  @warning_key {RemoteDesktopWebRTC, :turn_static_credential_warning_emitted}

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers)
    :persistent_term.erase(@warning_key)

    on_exit(fn ->
      restore_env(:remote_access_desktop_webrtc_ice_servers, previous)
      :persistent_term.erase(@warning_key)
    end)

    :ok
  end

  test "warns once when TURN credentials are static" do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers, [
      %{urls: ["turn:turn.example.com:3478"], username: "static-user", credential: "secret"}
    ])

    log =
      capture_log(fn ->
        assert [%{username: "static-user", credential: "secret"}] = RemoteDesktopWebRTC.ice_servers()
        assert [%{username: "static-user", credential: "secret"}] = RemoteDesktopWebRTC.ice_servers()
      end)

    assert log =~ "TURN credentials should be ephemeral"
    assert log |> String.split("TURN credentials should be ephemeral") |> length() == 2
  end

  test "accepts time-bound TURN usernames without warning" do
    expires_at = System.system_time(:second) + 300

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers, [
      %{
        urls: ["turns:turn.example.com:5349"],
        username: "#{expires_at}:user-1",
        credential: "secret"
      }
    ])

    log =
      capture_log(fn ->
        assert [%{username: username, credential: "secret"}] = RemoteDesktopWebRTC.ice_servers()
        assert username == "#{expires_at}:user-1"
      end)

    refute log =~ "TURN credentials should be ephemeral"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
