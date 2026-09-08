defmodule ServiceRadarWebNGWeb.Api.RemoteAccessRecordingControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.Auth.Guardian

  defmodule AuditSink do
    @moduledoc false
    def write_async(_opts), do: :ok
  end

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    user = grant_permissions(user, ["devices.remote_access.rdp.open"])
    {:ok, token, _claims} = Guardian.create_access_token(user)

    %{conn: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
  end

  test "RDP-only user can read RDP recording metadata", %{conn: conn, user: user} do
    recording = recording_fixture(user, :rdp)

    conn = get(conn, ~p"/api/remote-access/recordings/#{recording.id}")

    body = json_response(conn, 200)
    assert body["data"]["manifest"]["protocol"] == "rdp"
    assert body["data"]["manifest"]["target_port"] == 3389
    refute Map.has_key?(body["data"], "storage_backend")
    refute Map.has_key?(body["data"], "storage_bucket")
    refute Map.has_key?(body["data"], "object_key")
    refute Map.has_key?(body["data"]["manifest"], "storage_backend")
    refute Map.has_key?(body["data"]["manifest"], "storage_bucket")
    refute Map.has_key?(body["data"]["manifest"], "object_key")
    refute inspect(body) =~ "datasvc_object_store"
    refute inspect(body) =~ "remote-access-recordings"
    refute inspect(body) =~ "recording.jsonl"
  end

  test "RDP-only user can read RDP recording events", %{conn: conn, user: user} do
    recording = recording_fixture(user, :rdp)

    conn = get(conn, ~p"/api/remote-access/recordings/#{recording.id}/events")

    body = json_response(conn, 200)
    recording_session_id = recording.session_id

    assert [
             %{
               "event_type" => "desktop_frame_metadata",
               "payload_redacted" => true,
               "prior_event_hash" => nil,
               "session_id" => ^recording_session_id
             }
           ] = body["data"]

    refute inspect(body) =~ "very-secret"
  end

  test "RDP user cannot read another user's RDP recording without view-all permission", %{
    conn: conn
  } do
    owner = AccountsFixtures.user_fixture(%{role: :viewer})
    recording = recording_fixture(owner, :rdp)

    conn = get(conn, ~p"/api/remote-access/recordings/#{recording.id}")

    assert %{"error" => "remote_access_recording_not_found"} = json_response(conn, 404)
  end

  test "RDP user cannot read another user's RDP recording events without view-all permission", %{
    conn: conn
  } do
    owner = AccountsFixtures.user_fixture(%{role: :viewer})
    recording = recording_fixture(owner, :rdp)

    conn = get(conn, ~p"/api/remote-access/recordings/#{recording.id}/events")

    assert %{"error" => "remote_access_recording_not_found"} = json_response(conn, 404)
  end

  test "RDP user with view-all permission can read another user's RDP recording", %{
    conn: conn,
    user: user
  } do
    grant_permissions(user, [
      "devices.remote_access.rdp.open",
      "devices.remote_access.recordings.view_all"
    ])

    owner = AccountsFixtures.user_fixture(%{role: :viewer})
    recording = recording_fixture(owner, :rdp)

    conn = get(conn, ~p"/api/remote-access/recordings/#{recording.id}")

    body = json_response(conn, 200)
    assert body["data"]["id"] == recording.id
    assert body["data"]["manifest"]["protocol"] == "rdp"
  end

  test "recording export does not expose storage identifiers", %{conn: conn, user: user} do
    user =
      grant_permissions(user, [
        "devices.remote_access.rdp.open",
        "devices.remote_access.recordings.export"
      ])

    recording = recording_fixture(user, :rdp)

    conn = get(conn, ~p"/api/remote-access/recordings/#{recording.id}/export")

    body = json_response(conn, 200)
    refute Map.has_key?(body["data"]["recording"], "storage_backend")
    refute Map.has_key?(body["data"]["recording"], "storage_bucket")
    refute Map.has_key?(body["data"]["recording"], "object_key")
    refute Map.has_key?(body["data"]["manifest"], "storage_backend")
    refute Map.has_key?(body["data"]["manifest"], "storage_bucket")
    refute Map.has_key?(body["data"]["manifest"], "object_key")
    assert body["data"]["manifest"]["event_chain_verified"] == true
    assert is_binary(body["data"]["manifest"]["event_chain_root"])
    refute inspect(body) =~ "datasvc_object_store"
    refute inspect(body) =~ "remote-access-recordings"
    refute inspect(body) =~ "recording.jsonl"
  end

  test "recording export requires ownership or view-all permission", %{conn: conn, user: user} do
    grant_permissions(user, [
      "devices.remote_access.rdp.open",
      "devices.remote_access.recordings.export"
    ])

    owner = AccountsFixtures.user_fixture(%{role: :viewer})
    recording = recording_fixture(owner, :rdp)

    conn = get(conn, ~p"/api/remote-access/recordings/#{recording.id}/export")

    assert %{"error" => "remote_access_recording_not_found"} = json_response(conn, 404)
  end

  test "recording export refuses active recordings", %{conn: conn, user: user} do
    user =
      grant_permissions(user, [
        "devices.remote_access.rdp.open",
        "devices.remote_access.recordings.export"
      ])

    recording = active_recording_fixture(user, :rdp)

    conn = get(conn, ~p"/api/remote-access/recordings/#{recording.id}/export")

    assert %{"error" => "recording_not_exportable"} = json_response(conn, 409)
  end

  test "recording delete marks a terminal deleted state and playback/export return gone", %{
    conn: conn,
    user: user
  } do
    user =
      grant_permissions(user, [
        "devices.remote_access.rdp.open",
        "devices.remote_access.recordings.delete",
        "devices.remote_access.recordings.export"
      ])

    recording = recording_fixture(user, :rdp)

    conn = delete(conn, ~p"/api/remote-access/recordings/#{recording.id}")
    assert response(conn, 204) == ""

    assert {:ok, %RemoteAccessRecording{status: :deleted}} =
             RemoteAccessRecording.get_by_id(recording.id, actor: system_actor())

    conn = get(recycle(conn), ~p"/api/remote-access/recordings/#{recording.id}/events")
    assert %{"error" => "remote_access_recording_deleted"} = json_response(conn, 410)

    conn = get(recycle(conn), ~p"/api/remote-access/recordings/#{recording.id}/export")
    assert %{"error" => "remote_access_recording_deleted"} = json_response(conn, 410)
  end

  test "RDP-only user cannot read SSH recording metadata", %{conn: conn, user: user} do
    recording = recording_fixture(user, :ssh)

    conn = get(conn, ~p"/api/remote-access/recordings/#{recording.id}")

    assert %{"error" => "forbidden"} = json_response(conn, 403)
  end

  defp recording_fixture(user, protocol) do
    port = if protocol == :rdp, do: 3389, else: 22

    {:ok, session} =
      RemoteAccessSession.create_session(
        %{
          attach_ticket_hash:
            :sha256
            |> :crypto.hash("ticket-#{System.unique_integer([:positive])}")
            |> Base.encode16(case: :lower),
          attach_expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          device_uid: "recording-api-device-#{System.unique_integer([:positive])}",
          target_kind: :inventory_device,
          target_host: "recording-api.example.test",
          target_port: port,
          protocol: protocol,
          adapter: protocol,
          agent_id: "agent-recording-api",
          gateway_id: "gateway-recording-api",
          credential_custody_mode: :user_present,
          requested_by: user.id,
          recording_policy: %{"enabled" => true, "retention_days" => 7},
          metadata: %{}
        },
        actor: system_actor()
      )

    {:ok, recording} =
      RemoteAccessRecordings.ensure_for_session(session,
        audit_writer: AuditSink,
        audit_actor: system_actor()
      )

    {:ok, _event} =
      RemoteAccessRecordings.record_event(
        recording,
        %{
          stream: :output,
          event_type: event_type(protocol),
          data: "token=PVEAPIToken=very-secret\n",
          session_id: Ecto.UUID.generate(),
          sequence: 1
        },
        actor: system_actor()
      )

    {:ok, %RemoteAccessRecording{} = completed} =
      RemoteAccessRecordings.complete(
        recording,
        %{input_bytes: 0, output_bytes: 31, event_count: 1},
        audit_writer: AuditSink,
        audit_actor: system_actor()
      )

    completed
  end

  defp active_recording_fixture(user, protocol) do
    {:ok, recording} =
      user
      |> recording_session(protocol)
      |> RemoteAccessRecordings.ensure_for_session(
        audit_writer: AuditSink,
        audit_actor: system_actor()
      )

    {:ok, active} =
      RemoteAccessRecordings.activate(recording,
        audit_writer: AuditSink,
        audit_actor: system_actor()
      )

    active
  end

  defp recording_session(user, protocol) do
    port = if protocol == :rdp, do: 3389, else: 22

    {:ok, session} =
      RemoteAccessSession.create_session(
        %{
          attach_ticket_hash:
            :sha256
            |> :crypto.hash("ticket-#{System.unique_integer([:positive])}")
            |> Base.encode16(case: :lower),
          attach_expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          device_uid: "recording-api-device-#{System.unique_integer([:positive])}",
          target_kind: :inventory_device,
          target_host: "recording-api.example.test",
          target_port: port,
          protocol: protocol,
          adapter: protocol,
          agent_id: "agent-recording-api",
          gateway_id: "gateway-recording-api",
          credential_custody_mode: :user_present,
          requested_by: user.id,
          recording_policy: %{"enabled" => true, "retention_days" => 7},
          metadata: %{}
        },
        actor: system_actor()
      )

    session
  end

  defp event_type(:rdp), do: "desktop_frame_metadata"
  defp event_type(_protocol), do: "terminal_output"

  defp grant_permissions(user, permissions) do
    unique = System.unique_integer([:positive])

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "RDP recording API #{unique}",
          description: "Test profile for RDP recording API permissions",
          permissions: permissions
        },
        actor: system_actor(),
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    updated =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: system_actor())
      |> Ash.update!()

    RBAC.clear_process_cache()
    RBAC.Cache.put(updated.id, MapSet.new(permissions))

    updated
  end
end
