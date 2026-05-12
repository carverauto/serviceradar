defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessRecordingsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadar.Edge.RemoteAccessSession
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
    assert html =~ "No recordings found"
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
    refute html =~ "very-secret"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp recording_fixture(user) do
    {:ok, session} =
      RemoteAccessSession.create_session(
        %{
          attach_ticket_hash:
            :crypto.hash(:sha256, "ticket-#{System.unique_integer([:positive])}")
            |> Base.encode16(case: :lower),
          attach_expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          device_uid: "recording-ui-device-#{System.unique_integer([:positive])}",
          target_kind: :inventory_device,
          target_host: "recording-ui.example.test",
          target_port: 22,
          protocol: :ssh,
          adapter: :ssh,
          agent_id: "agent-recording-ui",
          gateway_id: "gateway-recording-ui",
          credential_custody_mode: :user_present,
          requested_by: user.id,
          recording_policy: %{
            "enabled" => true,
            "record_terminal_payloads" => true,
            "retention_days" => 7
          },
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
          event_type: "terminal_output",
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
end
