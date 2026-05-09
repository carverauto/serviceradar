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

  defmodule ApprovalRejector do
    @moduledoc false

    def authorize_remote_access_approval(context, _opts) do
      send(Process.get(:remote_access_audit_owner), {:approval_checked, context})
      {:error, :approval_denied}
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

  test "centrally brokered SSH custody requires an approval id" do
    uid = unique_uid("approval-required")
    insert_device!(uid, agent_id: "agent-approval", gateway_id: "gateway-approval")

    assert {:error, :approval_required} =
             RemoteAccessSessions.request_open(
               uid,
               %{protocol: :ssh, credential_custody_mode: :centrally_brokered},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "approval_required"
    assert denial_audit[:details][:failure_reason] == "approval_required"
  end

  test "approval policy stores only the approval id after the gate passes" do
    uid = unique_uid("approved")
    insert_device!(uid, agent_id: "agent-approved", gateway_id: "gateway-approved")
    approval_id = Ecto.UUID.generate()

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approval_id
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert session.approval_id == approval_id
    assert session.rbac_decision == :allowed

    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:details][:approval_id] == approval_id
    assert create_audit[:details][:rbac_decision] == "allowed"
  end

  test "approval checker can deny a supplied approval id" do
    uid = unique_uid("approval-denied")
    insert_device!(uid, agent_id: "agent-denied", gateway_id: "gateway-denied")
    approval_id = Ecto.UUID.generate()

    assert {:error, :approval_denied} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approval_id
               },
               actor: @system_actor,
               audit_writer: AuditSink,
               approval_checker: ApprovalRejector
             )

    assert_receive {:approval_checked, %{approval_id: ^approval_id, approval_required?: true}}
    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "denied"
    assert denial_audit[:details][:failure_reason] == "approval_denied"
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

  test "open frame and ready frame transitions advance durable session state" do
    uid = unique_uid("opening")
    insert_device!(uid, agent_id: "agent-open", gateway_id: "gateway-open")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(uid, %{},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}

    assert {:ok, opening} =
             RemoteAccessSessions.mark_opening(session.id, audit_writer: AuditSink)

    assert opening.status == :opening
    assert_receive {:remote_access_audit, opening_audit}
    assert opening_audit[:action] == :remote_access_session_opening

    assert {:ok, active} =
             RemoteAccessSessions.activate_session(session.id, audit_writer: AuditSink)

    assert active.status == :active
    assert_receive {:remote_access_audit, active_audit}
    assert active_audit[:action] == :remote_access_session_active
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
