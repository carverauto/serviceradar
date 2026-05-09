defmodule ServiceRadar.Edge.RemoteAccessSessionsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSessions
  alias ServiceRadar.Repo

  defmodule AuditSink do
    @moduledoc false

    def write_async(opts) do
      send(Process.get(:remote_access_audit_owner), {:remote_access_audit, opts})
      :ok
    end
  end

  @system_actor SystemActor.system(:remote_access_sessions_test)

  setup do
    Process.put(:remote_access_audit_owner, self())
    :ok
  end

  test "attach tickets are single-use and credential material is not persisted in metadata" do
    uid = unique_uid("ticket")
    insert_device!(uid, agent_id: "agent-ticket", gateway_id: "gateway-ticket")

    assert {:ok, %{session: session, ticket: ticket}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: "ssh",
                 credential_custody_mode: "ssh_certificate",
                 cols: 120,
                 rows: 40,
                 metadata: %{
                   "private_key" => private_key_fixture(),
                   "password" => "not-persisted",
                   "safe" => "kept"
                 }
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    refute inspect(session) =~ ticket
    assert session.protocol == :ssh
    assert session.credential_custody_mode == :ssh_certificate
    assert session.agent_id == "agent-ticket"
    assert session.gateway_id == "gateway-ticket"
    assert session.metadata["private_key"] == "REDACTED"
    assert session.metadata["password"] == "REDACTED"
    assert session.metadata["safe"] == "kept"
    assert session.metadata["terminal"]["cols"] == 120
    refute inspect(session.metadata) =~ "PRIVATE KEY"
    refute inspect(session.metadata) =~ "not-persisted"

    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:action] == :remote_access_session_create
    assert create_audit[:details][:protocol] == "ssh"
    assert create_audit[:details][:credential_custody_mode] == "ssh_certificate"
    refute inspect(create_audit) =~ "PRIVATE KEY"
    refute inspect(create_audit) =~ "not-persisted"

    assert {:ok, %RemoteAccessSession{status: :attached}} =
             RemoteAccessSessions.attach_with_ticket(ticket,
               session_id: session.id,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, attach_audit}
    assert attach_audit[:action] == :remote_access_session_attach

    assert {:error, :invalid_or_expired_ticket} =
             RemoteAccessSessions.attach_with_ticket(ticket,
               session_id: session.id,
               audit_writer: AuditSink
             )
  end

  test "generic SSH rejects agent-local reusable credential custody" do
    uid = unique_uid("agent-local")
    insert_device!(uid, agent_id: "agent-local", gateway_id: "gateway-local")

    assert {:error, :unsupported_credential_custody_mode} =
             RemoteAccessSessions.request_open(
               uid,
               %{protocol: :ssh, credential_custody_mode: "agent_local"},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "denied"
  end

  test "lifecycle transitions write sanitized terminal outcomes" do
    uid = unique_uid("lifecycle")
    insert_device!(uid, agent_id: "agent-life", gateway_id: "gateway-life")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(uid, %{},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}

    assert {:ok, closing} =
             RemoteAccessSessions.request_close(session.id,
               reason: "operator",
               audit_writer: AuditSink
             )

    assert closing.status == :closing
    assert_receive {:remote_access_audit, close_requested_audit}
    assert close_requested_audit[:action] == :remote_access_session_close_requested
    assert close_requested_audit[:details][:close_reason] == "operator"

    assert {:ok, closed} =
             RemoteAccessSessions.close_session(session.id,
               reason: "operator",
               outcome: "completed",
               audit_writer: AuditSink
             )

    assert closed.status == :closed
    assert closed.outcome == :completed
    assert_receive {:remote_access_audit, closed_audit}
    assert closed_audit[:action] == :remote_access_session_closed
    assert closed_audit[:details][:terminal_outcome] == "completed"
  end

  test "provider-console sessions default to provider-ticket custody without key storage" do
    uid = unique_uid("provider")
    insert_device!(uid, agent_id: "agent-provider", gateway_id: "gateway-provider")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :proxmox_console,
                 adapter: :proxmox_console,
                 target_kind: :provider_console,
                 metadata: %{"ticket" => "pve-temporary-ticket"}
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert session.protocol == :proxmox_console
    assert session.adapter == :proxmox_console
    assert session.credential_custody_mode == :provider_ticket
    assert session.metadata["ticket"] == "REDACTED"
    refute inspect(session.metadata) =~ "pve-temporary-ticket"
  end

  defp insert_device!(uid, opts) do
    now = DateTime.utc_now()

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: uid,
        vendor_name: "Linux",
        agent_id: Keyword.get(opts, :agent_id),
        gateway_id: Keyword.get(opts, :gateway_id),
        is_available: true,
        metadata: %{},
        first_seen_time: now,
        last_seen_time: now
      }
    ])
  end

  defp unique_uid(label), do: "remote-access-#{label}-#{System.unique_integer([:positive])}"

  defp private_key_fixture do
    """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACB5Qw8C1g64mHaVnq1m6+xR54Xq7gkPsFQj7u3lK4P4JAAAAJB0ZXN0dGVz
    dAAAAAtzc2gtZWQyNTUxOQAAACB5Qw8C1g64mHaVnq1m6+xR54Xq7gkPsFQj7u3lK4P4JAAA
    AEB0ZXN0LWtleS1tYXRlcmlhbAAAAAAAAAAA
    -----END OPENSSH PRIVATE KEY-----
    """
  end
end
