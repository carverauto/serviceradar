defmodule ServiceRadar.Edge.RemoteAccessSessionsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordings
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

  defmodule ApprovalApprover do
    @moduledoc false

    def authorize_remote_access_approval(context, _opts) do
      send(Process.get(:remote_access_audit_owner), {:approval_checked, context})
      :ok
    end
  end

  @system_actor SystemActor.system(:remote_access_sessions_test)

  setup do
    previous_policy =
      Application.get_env(:serviceradar_core, :remote_access_ssh_certificate_policy)

    Process.put(:remote_access_audit_owner, self())

    on_exit(fn ->
      if previous_policy do
        Application.put_env(
          :serviceradar_core,
          :remote_access_ssh_certificate_policy,
          previous_policy
        )
      else
        Application.delete_env(:serviceradar_core, :remote_access_ssh_certificate_policy)
      end
    end)

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
                 credential_custody_mode: "user_present",
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
    assert session.credential_custody_mode == :user_present
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
    assert create_audit[:details][:credential_custody_mode] == "user_present"
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

  test "generic SSH rejects provider-ticket and no-credential custody modes" do
    uid = unique_uid("ssh-custody")
    insert_device!(uid, agent_id: "agent-custody", gateway_id: "gateway-custody")

    for custody_mode <- [:provider_ticket, :none] do
      assert {:error, :unsupported_credential_custody_mode} =
               RemoteAccessSessions.request_open(
                 uid,
                 %{protocol: :ssh, credential_custody_mode: custody_mode},
                 actor: @system_actor,
                 audit_writer: AuditSink
               )

      assert_receive {:remote_access_audit, denial_audit}
      assert denial_audit[:action] == :remote_access_session_denied
      assert denial_audit[:details][:rbac_decision] == "denied"
      assert denial_audit[:details][:failure_reason] == "unsupported_credential_custody_mode"
    end
  end

  test "SSH certificate sessions require trusted principal policy" do
    uid = unique_uid("ssh-cert-policy-required")
    insert_device!(uid, agent_id: "agent-policy-required", gateway_id: "gateway-policy-required")

    assert {:error, :ssh_principal_policy_required} =
             RemoteAccessSessions.request_open(
               uid,
               %{protocol: :ssh, credential_custody_mode: :ssh_certificate},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "denied"
    assert denial_audit[:details][:failure_reason] == "ssh_principal_policy_required"
  end

  test "SSH certificate sessions copy trusted principal policy from deployment config" do
    uid = unique_uid("ssh-cert-policy")

    Application.put_env(:serviceradar_core, :remote_access_ssh_certificate_policy, %{
      "allowed_principals" => ["ubuntu"],
      "principal_mappings" => [
        %{"source" => "groups", "value" => "linux-admins", "principals" => ["ubuntu"]}
      ],
      "ttl_seconds" => 900,
      "targets" => %{
        uid => %{
          "allowed_principals" => ["root"],
          "ttl_seconds" => 600
        }
      }
    })

    insert_device!(uid, agent_id: "agent-policy", gateway_id: "gateway-policy")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :ssh_certificate,
                 metadata: %{
                   "safe" => "kept",
                   "ssh_allowed_principals" => ["client-controlled"],
                   "ssh_certificate_ttl_seconds" => 28_800
                 }
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert session.metadata["safe"] == "kept"
    assert session.metadata["ssh_allowed_principals"] == ["root"]
    assert session.metadata["ssh_certificate_ttl_seconds"] == 600

    assert session.metadata["ssh_principal_mappings"] == [
             %{"source" => "groups", "value" => "linux-admins", "principals" => ["ubuntu"]}
           ]
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
               audit_writer: AuditSink,
               approval_checker: ApprovalApprover
             )

    assert_receive {:approval_checked, %{approval_id: ^approval_id, approval_required?: true}}
    assert session.approval_id == approval_id
    assert session.rbac_decision == :allowed

    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:details][:approval_id] == approval_id
    assert create_audit[:details][:rbac_decision] == "allowed"
  end

  test "approval-required sessions fail closed without an approval checker" do
    uid = unique_uid("approval-checker-required")

    insert_device!(uid,
      agent_id: "agent-checker-required",
      gateway_id: "gateway-checker-required"
    )

    approval_id = Ecto.UUID.generate()

    assert {:error, :approval_checker_required} =
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

    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "denied"
    assert denial_audit[:details][:failure_reason] == "approval_checker_required"
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
             RemoteAccessSessions.request_open(
               uid,
               %{credential_custody_mode: :user_present},
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
             RemoteAccessSessions.request_open(
               uid,
               %{credential_custody_mode: :user_present},
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

  test "recording manifests store retention and counters without terminal payloads" do
    uid = unique_uid("recording")
    insert_device!(uid, agent_id: "agent-recording", gateway_id: "gateway-recording")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :user_present,
                 recording_policy: %{
                   "enabled" => true,
                   "mode" => "metadata",
                   "retention_days" => 7,
                   "private_key" => private_key_fixture(),
                   "storage" => %{"bucket" => "ra-test", "prefix" => "edge"}
                 }
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:action] == :remote_access_session_create

    assert {:ok, %RemoteAccessRecording{} = recording} =
             RemoteAccessRecordings.ensure_for_session(session,
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert recording.status == :pending
    assert recording.session_id == session.id
    assert recording.storage_backend == "datasvc_object_store"
    assert recording.storage_bucket == "ra-test"
    assert recording.object_key == "edge/sessions/#{session.id}/recording.jsonl"
    assert recording.policy["private_key"] == "REDACTED"
    assert recording.manifest["raw_terminal_payloads_stored"] == false
    assert recording.retention_expires_at
    assert DateTime.after?(recording.retention_expires_at, DateTime.utc_now())
    refute inspect(recording) =~ "OPENSSH PRIVATE KEY"

    assert_receive {:remote_access_audit, recording_create_audit}
    assert recording_create_audit[:action] == :remote_access_recording_created
    assert recording_create_audit[:resource_type] == "remote_access_recording"

    assert {:ok, active} =
             RemoteAccessRecordings.activate(recording,
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert active.status == :active
    assert_receive {:remote_access_audit, recording_active_audit}
    assert recording_active_audit[:action] == :remote_access_recording_active

    assert {:ok, completed} =
             RemoteAccessRecordings.complete(
               active,
               %{input_bytes: 7, output_bytes: 5, event_count: 2},
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert completed.status == :completed
    assert completed.input_bytes == 7
    assert completed.output_bytes == 5
    assert completed.event_count == 2
    assert completed.manifest["raw_terminal_payloads_stored"] == false
    refute inspect(completed) =~ "whoami"
    refute inspect(completed) =~ "root"

    assert_receive {:remote_access_audit, recording_complete_audit}
    assert recording_complete_audit[:action] == :remote_access_recording_completed
    assert recording_complete_audit[:details][:input_bytes] == 7
    assert recording_complete_audit[:details][:output_bytes] == 5
    assert recording_complete_audit[:details][:event_count] == 2

    assert {:ok, fetched} = RemoteAccessRecording.get_by_session(session.id, actor: @system_actor)
    assert fetched.id == completed.id
  end

  test "recording manifests are skipped unless policy enables recording" do
    uid = unique_uid("recording-disabled")
    insert_device!(uid, agent_id: "agent-recording-disabled", gateway_id: "gateway-recording")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{credential_custody_mode: :user_present},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}

    assert {:ok, nil} =
             RemoteAccessRecordings.ensure_for_session(session,
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    refute_receive {:remote_access_audit, %{action: :remote_access_recording_created}}, 50
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
