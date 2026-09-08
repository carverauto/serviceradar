defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessRecordingsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  defmodule AuditSink do
    @moduledoc false
    def write_async(_opts), do: :ok
  end

  setup :register_and_log_in_admin_user

  test "renders the recordings settings route", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/recordings")

    assert html =~ "Remote Access Recordings"
  end

  test "viewer is blocked from recordings settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/recordings")
    assert to == ~p"/settings/profile"
  end

  test "renders selected replay events without exposing redacted payloads", %{
    conn: conn,
    user: user
  } do
    recording = recording_fixture(user)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/recordings/#{recording.id}")

    assert html =~ "Replay Events"
    assert html =~ "terminal_output"
    assert html =~ "REDACTED"
    assert html =~ "credential redaction"
    assert html =~ "Terminal payloads stored by policy"
    refute html =~ "datasvc_object_store"
    refute html =~ "remote-access-recordings"
    refute html =~ "recording.jsonl"
    refute html =~ "very-secret"
  end

  test "RDP-only user can review RDP metadata recordings without SSH permission", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    user = grant_permissions(user, ["devices.remote_access.rdp.open"])

    rdp_recording = recording_fixture(user, protocol: :rdp, store_payloads?: false)
    ssh_recording = recording_fixture(user, protocol: :ssh)
    other_user = AccountsFixtures.user_fixture(%{role: :viewer})
    other_rdp_recording = recording_fixture(other_user, protocol: :rdp, store_payloads?: false)
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/recordings/#{rdp_recording.id}")

    assert html =~ "Replay Events"
    assert html =~ "desktop_frame_metadata"
    assert html =~ "Metadata-only"
    assert html =~ "rdp:recording-ui.example.test:3389"
    assert html =~ "Started"
    assert html =~ "Completed"
    assert html =~ "Failure"
    assert html =~ "Desktop Policy Snapshot"
    assert html =~ "User present"
    assert html =~ "Verify full TLS"
    assert html =~ "NLA required"
    assert html =~ "1920x1080"
    assert html =~ "Clipboard disabled"
    assert html =~ "Drive disabled"
    assert html =~ "Allowed"
    refute html =~ "ssh:recording-ui.example.test:22"
    refute html =~ ssh_recording.id
    refute html =~ other_rdp_recording.id
  end

  test "RDP user with view-all permission can review another user's RDP recording", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})

    user =
      grant_permissions(user, [
        "devices.remote_access.rdp.open",
        "devices.remote_access.recordings.view_all"
      ])

    owner = AccountsFixtures.user_fixture(%{role: :viewer})
    rdp_recording = recording_fixture(owner, protocol: :rdp, store_payloads?: false)
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/recordings/#{rdp_recording.id}")

    assert html =~ "Replay Events"
    assert html =~ "desktop_frame_metadata"
    assert html =~ rdp_recording.id
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp recording_fixture(user, opts \\ []) do
    protocol = Keyword.get(opts, :protocol, :ssh)
    store_payloads? = Keyword.get(opts, :store_payloads?, true)
    port = if protocol == :rdp, do: 3389, else: 22

    {:ok, session} =
      RemoteAccessSession.create_session(
        %{
          attach_ticket_hash:
            :sha256
            |> :crypto.hash("ticket-#{System.unique_integer([:positive])}")
            |> Base.encode16(case: :lower),
          attach_expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          device_uid: "recording-ui-device-#{System.unique_integer([:positive])}",
          target_kind: :inventory_device,
          target_host: "recording-ui.example.test",
          target_port: port,
          protocol: protocol,
          adapter: protocol,
          agent_id: "agent-recording-ui",
          gateway_id: "gateway-recording-ui",
          credential_custody_mode: :user_present,
          requested_by: user.id,
          recording_policy: %{
            "enabled" => true,
            "record_terminal_payloads" => store_payloads?,
            "retention_days" => 7
          },
          metadata: desktop_metadata(protocol)
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

  defp event_type(:rdp), do: "desktop_frame_metadata"
  defp event_type(_protocol), do: "terminal_output"

  defp desktop_metadata(:rdp) do
    %{
      "target_tls" => %{
        "mode" => "verify_full",
        "server_name" => "recording-ui.example.test"
      },
      "nla" => %{"required" => true},
      "screen_policy" => %{
        "max_width" => 1920,
        "max_height" => 1080,
        "max_frame_rate" => 30,
        "max_bitrate_kbps" => 8_000
      },
      "redirection_policy" => %{
        "clipboard" => "disabled",
        "drive" => false
      }
    }
  end

  defp desktop_metadata(_protocol), do: %{}

  defp grant_permissions(user, permissions) do
    unique = System.unique_integer([:positive])

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "RDP recording LiveView #{unique}",
          description: "Test profile for RDP recording LiveView permissions",
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
