defmodule ServiceRadar.Edge.RemoteAccessSessionsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.RemoteAccessApplicationTarget
  alias ServiceRadar.Edge.RemoteAccessCentralCredentialGrants
  alias ServiceRadar.Edge.RemoteAccessFileTransfer
  alias ServiceRadar.Edge.RemoteAccessFileTransfers
  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordingEvent
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadar.Edge.RemoteAccessRequest
  alias ServiceRadar.Edge.RemoteAccessRequests
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSessions
  alias ServiceRadar.Edge.RemoteAccessTcpTarget
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

  test "registered application target resolves trusted upstream policy into the session" do
    uid = unique_uid("app-target")
    insert_device!(uid, agent_id: "device-agent", gateway_id: "device-gateway")

    assert {:ok, target} =
             RemoteAccessApplicationTarget.create_target(
               %{
                 name: "Internal App",
                 device_uid: uid,
                 agent_id: "agent-app",
                 gateway_id: "gateway-app",
                 upstream_scheme: :https,
                 upstream_host: "10.20.30.40",
                 upstream_port: 8443,
                 upstream_host_header: "internal-app.example.test",
                 upstream_sni: "internal-app.example.test",
                 allowed_methods: ["GET", "POST"],
                 allowed_path_prefixes: ["/app"],
                 tls_policy: %{"verify" => "required"},
                 quota_policy: %{"idle_timeout_seconds" => 300},
                 recording_policy: %{"enabled" => true},
                 metadata: %{"owner" => "platform"}
               },
               actor: @system_actor
             )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               target.id,
               %{target_kind: :registered_application_target},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert session.device_uid == uid
    assert session.target_kind == :registered_application_target
    assert session.protocol == :app
    assert session.adapter == :application
    assert session.target_host == "10.20.30.40"
    assert session.target_port == 8443
    assert session.agent_id == "agent-app"
    assert session.gateway_id == "gateway-app"
    assert session.credential_custody_mode == :none
    assert session.idle_timeout_seconds == 300
    assert session.metadata["target_id"] == target.id
    assert session.metadata["target_type"] == "application"
    assert session.metadata["upstream_host_header"] == "internal-app.example.test"
    assert session.metadata["allowed_path_prefixes"] == ["/app"]
    assert session.metadata["target_metadata"] == %{"owner" => "platform"}

    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:action] == :remote_access_session_create
    assert create_audit[:details][:protocol] == "app"
  end

  test "registered TCP target resolves trusted upstream policy into the session" do
    uid = unique_uid("tcp-target")
    insert_device!(uid, agent_id: "device-agent", gateway_id: "device-gateway")

    assert {:ok, target} =
             RemoteAccessTcpTarget.create_target(
               %{
                 name: "Internal TCP",
                 device_uid: uid,
                 agent_id: "agent-tcp",
                 gateway_id: "gateway-tcp",
                 upstream_host: "10.30.40.50",
                 upstream_port: 5432,
                 protocol_name: "postgres",
                 idle_timeout_seconds: 120,
                 absolute_timeout_seconds: 600,
                 quota_policy: %{"max_rx_bytes" => 1_048_576},
                 metadata: %{"owner" => "database"}
               },
               actor: @system_actor
             )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               target.id,
               %{target_kind: :registered_tcp_target},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert session.device_uid == uid
    assert session.target_kind == :registered_tcp_target
    assert session.protocol == :tcp
    assert session.adapter == :tcp
    assert session.target_host == "10.30.40.50"
    assert session.target_port == 5432
    assert session.agent_id == "agent-tcp"
    assert session.gateway_id == "gateway-tcp"
    assert session.credential_custody_mode == :none
    assert session.idle_timeout_seconds == 120
    assert session.absolute_timeout_seconds == 600
    assert session.metadata["target_id"] == target.id
    assert session.metadata["target_type"] == "tcp"
    assert session.metadata["protocol_name"] == "postgres"
    assert session.metadata["target_metadata"] == %{"owner" => "database"}

    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:action] == :remote_access_session_create
    assert create_audit[:details][:protocol] == "tcp"
  end

  test "disabled registered targets are rejected before a session is created" do
    uid = unique_uid("disabled-target")
    insert_device!(uid, agent_id: "device-agent", gateway_id: "device-gateway")

    assert {:ok, target} =
             RemoteAccessTcpTarget.create_target(
               %{
                 name: "Disabled TCP",
                 device_uid: uid,
                 enabled: false,
                 agent_id: "agent-tcp",
                 upstream_host: "10.30.40.60",
                 upstream_port: 3306
               },
               actor: @system_actor
             )

    assert {:error, :remote_access_target_disabled} =
             RemoteAccessSessions.request_open(
               target.id,
               %{target_kind: :registered_tcp_target},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:failure_reason] == "remote_access_target_disabled"
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

  test "attach ticket consume is atomic under concurrent attempts" do
    uid = unique_uid("ticket-race")
    insert_device!(uid, agent_id: "agent-ticket-race", gateway_id: "gateway-ticket-race")

    assert {:ok, %{session: session, ticket: ticket}} =
             RemoteAccessSessions.request_open(
               uid,
               %{protocol: "ssh", credential_custody_mode: "user_present"},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:action] == :remote_access_session_create

    parent = self()

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn ->
          Process.put(:remote_access_audit_owner, parent)

          RemoteAccessSessions.attach_with_ticket(ticket,
            session_id: session.id,
            audit_writer: AuditSink
          )
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, %RemoteAccessSession{status: :attached}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_or_expired_ticket})) == 1

    assert_receive {:remote_access_audit, attach_audit}
    assert attach_audit[:action] == :remote_access_session_attach

    refute_receive {:remote_access_audit, _duplicate_attach_audit}, 50
  end

  test "recording destroy requires service boundary authorization and writes audit" do
    uid = unique_uid("recording-delete")

    insert_device!(uid,
      agent_id: "agent-recording-delete",
      gateway_id: "gateway-recording-delete"
    )

    deleter_id = insert_user!("recording-delete")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{credential_custody_mode: :user_present},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}

    assert {:ok, recording} =
             RemoteAccessRecording.create_recording(
               %{
                 session_id: session.id,
                 policy: %{},
                 storage_backend: "datasvc_object_store",
                 object_key: "remote-access/sessions/#{session.id}/recording.jsonl"
               },
               actor: @system_actor
             )

    deleter = %{
      id: deleter_id,
      permissions: MapSet.new(["devices.remote_access.recordings.delete"])
    }

    assert {:error, _reason} = Ash.destroy(recording, actor: deleter, action: :destroy)

    assert :ok =
             RemoteAccessRecordings.destroy(recording,
               actor: deleter,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, destroy_audit}
    assert destroy_audit[:action] == :remote_access_recording_destroyed
    assert destroy_audit[:severity] == :high

    assert {:error, _reason} = RemoteAccessRecording.get_by_id(recording.id, actor: @system_actor)
  end

  test "file transfer destroy requires service boundary authorization and writes audit" do
    uid = unique_uid("file-transfer-delete")
    requester_id = insert_user!("file-transfer-requester")
    deleter_id = insert_user!("file-transfer-delete")
    insert_device!(uid, agent_id: "agent-transfer-delete", gateway_id: "gateway-transfer-delete")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{credential_custody_mode: :user_present},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}

    assert {:ok, transfer} =
             RemoteAccessFileTransfer.create_transfer(
               %{
                 session_id: session.id,
                 requested_by: requester_id,
                 device_uid: uid,
                 target_kind: :inventory_device,
                 target_host: uid,
                 target_port: 22,
                 agent_id: "agent-transfer-delete",
                 gateway_id: "gateway-transfer-delete",
                 operation: :download,
                 direction: :read,
                 protocol: :sftp,
                 credential_custody_mode: :user_present,
                 target_path: "/var/log/syslog",
                 redacted_path: "/var/log/syslog",
                 path_hash: String.duplicate("a", 64),
                 policy_snapshot: %{},
                 policy_decision: %{},
                 quota_snapshot: %{}
               },
               actor: @system_actor
             )

    deleter = %{
      id: deleter_id,
      permissions: MapSet.new(["devices.remote_access.files.delete"])
    }

    assert {:error, _reason} = Ash.destroy(transfer, actor: deleter, action: :destroy)

    assert :ok =
             RemoteAccessFileTransfers.destroy(transfer,
               actor: deleter,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, destroy_audit}
    assert destroy_audit[:action] == :remote_access_file_transfer_destroyed
    assert destroy_audit[:severity] == :high

    assert {:error, _reason} =
             RemoteAccessFileTransfer.get_by_id(transfer.id, actor: @system_actor)
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

    credential_rule_id =
      create_credential_rule!("approval-required", scope_value: "agent-approval").id

    assert {:error, :approval_required} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 credential_rule_id: credential_rule_id
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "approval_required"
    assert denial_audit[:details][:failure_reason] == "approval_required"
  end

  test "centrally brokered SSH custody requires a credential rule id" do
    uid = unique_uid("credential-rule-required")
    insert_device!(uid, agent_id: "agent-rule-required", gateway_id: "gateway-rule-required")
    approval_id = Ecto.UUID.generate()

    assert {:error, :credential_rule_required} =
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

    refute_receive {:approval_checked, _context}, 50
    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "denied"
    assert denial_audit[:details][:failure_reason] == "credential_rule_required"
  end

  test "centrally brokered SSH custody requires a scoped credential rule" do
    uid = unique_uid("credential-rule-scope")
    insert_device!(uid, agent_id: "agent-rule-scope", gateway_id: "gateway-rule-scope")
    approval_id = Ecto.UUID.generate()
    credential_rule_id = create_credential_rule!("scope-mismatch", scope_value: "other-agent").id

    assert {:error, :credential_rule_scope_mismatch} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approval_id,
                 credential_rule_id: credential_rule_id
               },
               actor: @system_actor,
               audit_writer: AuditSink,
               approval_checker: ApprovalApprover
             )

    refute_receive {:approval_checked, _context}, 50
    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "denied"
    assert denial_audit[:details][:failure_reason] == "credential_rule_scope_mismatch"
  end

  test "approval policy stores only the approval id after the gate passes" do
    uid = unique_uid("approved")
    insert_device!(uid, agent_id: "agent-approved", gateway_id: "gateway-approved")
    approval_id = Ecto.UUID.generate()
    credential_rule_id = create_credential_rule!("approved", scope_value: "agent-approved").id

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approval_id,
                 credential_rule_id: credential_rule_id
               },
               actor: @system_actor,
               audit_writer: AuditSink,
               approval_checker: ApprovalApprover
             )

    assert_receive {:approval_checked, %{approval_id: ^approval_id, approval_required?: true}}
    assert session.approval_id == approval_id
    assert session.credential_rule_id == credential_rule_id
    assert session.rbac_decision == :allowed

    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:details][:approval_id] == approval_id
    assert create_audit[:details][:credential_rule_id] == credential_rule_id
    assert create_audit[:details][:rbac_decision] == "allowed"
  end

  test "central credential grant resolver builds one-session scoped reference grants" do
    uid = unique_uid("central-grant")
    insert_device!(uid, agent_id: "agent-central-grant", gateway_id: "gateway-central-grant")
    approval_id = Ecto.UUID.generate()

    rule =
      create_credential_rule!("central-grant",
        scope_value: "agent-central-grant",
        metadata: %{"credential_broker_ttl_seconds" => 120}
      )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approval_id,
                 credential_rule_id: rule.id
               },
               actor: @system_actor,
               audit_writer: AuditSink,
               approval_checker: ApprovalApprover
             )

    assert_receive {:approval_checked, _context}
    assert_receive {:remote_access_audit, _create_audit}

    assert {:ok, grant} = RemoteAccessCentralCredentialGrants.build_broker_grant(session)

    broker = grant.broker_opts[:metadata]["credential_broker"]
    assert grant.broker_opts[:credential_mode] == "centrally_brokered"
    assert broker["schema"] == "serviceradar.edge_credential_broker_grant.v1"
    assert broker["grant_type"] == "ssh_session"
    assert broker["session_id"] == session.id
    assert broker["agent_id"] == "agent-central-grant"
    assert broker["gateway_id"] == "gateway-central-grant"
    assert broker["protocol"] == "ssh"
    assert broker["credential_rule_id"] == rule.id
    assert broker["credential_secret_ref"] =~ "credentialref:network-credential-secret:"
    assert broker["target"] == %{"device_uid" => uid, "host" => uid, "port" => 22}
    assert broker["allow"] == %{"protocols" => ["ssh"], "hosts" => [uid], "ports" => [22]}
    assert broker["ttl_seconds"] == 120
    assert grant.audit.gateway_id == "gateway-central-grant"
    refute inspect(grant.audit) =~ "credentialref:"
    refute inspect(grant) =~ "OPENSSH PRIVATE KEY"

    mismatched = %{session | agent_id: "other-agent"}

    assert {:error, :credential_rule_scope_mismatch} =
             RemoteAccessCentralCredentialGrants.build_broker_grant(mismatched)
  end

  test "approval-required sessions fail closed without an approved access request" do
    uid = unique_uid("approval-not-found")

    insert_device!(uid,
      agent_id: "agent-approval-not-found",
      gateway_id: "gateway-approval-not-found"
    )

    approval_id = Ecto.UUID.generate()

    credential_rule_id =
      create_credential_rule!("approval-not-found",
        scope_value: "agent-approval-not-found"
      ).id

    assert {:error, :approval_not_found} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approval_id,
                 credential_rule_id: credential_rule_id
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "approval_not_found"
    assert denial_audit[:details][:failure_reason] == "approval_not_found"
  end

  test "approved access request is bound to exactly one remote-access session" do
    uid = unique_uid("access-request")
    insert_device!(uid, agent_id: "agent-access-request", gateway_id: "gateway-access-request")

    credential_rule_id =
      create_credential_rule!("access-request", scope_value: "agent-access-request").id

    requester_id = insert_user!("requester")
    reviewer_id = insert_user!("reviewer")

    assert {:ok, access_request} =
             RemoteAccessRequests.create(
               %{
                 requested_by: requester_id,
                 device_uid: uid,
                 target_kind: :inventory_device,
                 target_host: uid,
                 target_port: 22,
                 protocol: :ssh,
                 adapter: :ssh,
                 agent_id: "agent-access-request",
                 gateway_id: "gateway-access-request",
                 credential_custody_mode: :centrally_brokered,
                 credential_rule_id: credential_rule_id,
                 reason: "break-glass maintenance",
                 ttl_seconds: 600,
                 metadata: %{"private_key" => private_key_fixture(), "safe" => "kept"}
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert access_request.status == :pending
    assert access_request.metadata["private_key"] == "REDACTED"

    assert_receive {:remote_access_audit, request_audit}
    assert request_audit[:action] == :remote_access_request_created
    refute inspect(request_audit) =~ "OPENSSH PRIVATE KEY"

    assert {:error, :approval_pending} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: access_request.id,
                 credential_rule_id: credential_rule_id
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, pending_denial}
    assert pending_denial[:details][:rbac_decision] == "approval_pending"

    assert {:ok, approved} =
             RemoteAccessRequests.approve(access_request,
               actor: %{id: reviewer_id, role: :system, email: "reviewer@example.test"},
               audit_writer: AuditSink,
               note: "approved for maintenance"
             )

    assert approved.status == :approved
    assert approved.approved_by == reviewer_id
    assert_receive {:remote_access_audit, approval_audit}
    assert approval_audit[:action] == :remote_access_request_approved

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approved.id,
                 credential_rule_id: credential_rule_id
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert session.approval_id == approved.id
    assert_receive {:remote_access_audit, consumed_audit}
    assert consumed_audit[:action] == :remote_access_request_consumed
    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:action] == :remote_access_session_create

    assert {:ok, consumed} = RemoteAccessRequests.get(approved.id, actor: @system_actor)
    assert consumed.status == :consumed
    assert consumed.session_id == session.id

    assert {:error, :approval_consumed} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approved.id,
                 credential_rule_id: credential_rule_id
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )
  end

  test "approval checker can deny a supplied approval id" do
    uid = unique_uid("approval-denied")
    insert_device!(uid, agent_id: "agent-denied", gateway_id: "gateway-denied")
    approval_id = Ecto.UUID.generate()

    credential_rule_id =
      create_credential_rule!("approval-denied", scope_value: "agent-denied").id

    assert {:error, :approval_denied} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approval_id,
                 credential_rule_id: credential_rule_id
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

  test "approval action policy forbids direct self approval even with spoofed approved_by" do
    uid = unique_uid("self-approval")
    requester_id = insert_user!("self-approval-requester")
    reviewer_id = insert_user!("self-approval-reviewer")
    insert_device!(uid, agent_id: "agent-self-approval", gateway_id: "gateway-self-approval")

    credential_rule_id =
      create_credential_rule!("self-approval", scope_value: "agent-self-approval").id

    assert {:ok, access_request} =
             RemoteAccessRequests.create(
               %{
                 requested_by: requester_id,
                 device_uid: uid,
                 target_kind: :inventory_device,
                 target_host: uid,
                 target_port: 22,
                 protocol: :ssh,
                 adapter: :ssh,
                 agent_id: "agent-self-approval",
                 gateway_id: "gateway-self-approval",
                 credential_custody_mode: :centrally_brokered,
                 credential_rule_id: credential_rule_id,
                 reason: "self approval should fail",
                 ttl_seconds: 600
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert {:error, _reason} =
             RemoteAccessRequest.approve(
               access_request,
               %{
                 approved_by: reviewer_id,
                 approved_at: RemoteAccessRequest.utc_now()
               },
               actor: %{
                 id: requester_id,
                 permissions: MapSet.new(["devices.remote_access.requests.review"])
               }
             )

    assert {:ok, pending} = RemoteAccessRequests.get(access_request.id, actor: @system_actor)
    assert pending.status == :pending
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

  test "recording events keep terminal payloads metadata-only unless content policy opts in" do
    uid = unique_uid("recording-events")
    insert_device!(uid, agent_id: "agent-recording-events", gateway_id: "gateway-recording")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :user_present,
                 recording_policy: %{
                   "enabled" => true,
                   "mode" => "metadata",
                   "retention_days" => 3
                 }
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}

    assert {:ok, %RemoteAccessRecording{} = recording} =
             RemoteAccessRecordings.ensure_for_session(session,
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert_receive {:remote_access_audit, recording_create_audit}
    assert recording_create_audit[:action] == :remote_access_recording_created

    assert {:ok, %RemoteAccessRecordingEvent{} = input_event} =
             RemoteAccessRecordings.record_event(
               recording,
               %{
                 stream: :input,
                 event_type: "terminal_input",
                 data: "sudo -S secret-password\n",
                 sequence: 1
               },
               actor: @system_actor
             )

    assert input_event.payload_text == nil
    assert input_event.payload_redacted == true
    assert input_event.redaction_reason == "content_recording_disabled"
    assert input_event.byte_count == byte_size("sudo -S secret-password\n")
    assert is_binary(input_event.payload_sha256)
    refute inspect(input_event) =~ "secret-password"

    assert {:ok, events} = RemoteAccessRecordings.list_events(recording, actor: @system_actor)
    assert Enum.map(events, & &1.sequence) == [1]
  end

  test "recording events store redacted output and export only with export permission" do
    uid = unique_uid("recording-event-content")
    insert_device!(uid, agent_id: "agent-recording-content", gateway_id: "gateway-recording")

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :user_present,
                 recording_policy: %{
                   "enabled" => true,
                   "record_terminal_payloads" => true,
                   "record_input" => false,
                   "retention_days" => 5
                 }
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}

    assert {:ok, %RemoteAccessRecording{} = recording} =
             RemoteAccessRecordings.ensure_for_session(session,
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert_receive {:remote_access_audit, recording_create_audit}
    assert recording_create_audit[:action] == :remote_access_recording_created

    assert recording.manifest["raw_terminal_payloads_stored"] == true

    assert {:ok, input_event} =
             RemoteAccessRecordings.record_event(
               recording,
               %{stream: :input, event_type: "terminal_input", data: "whoami\n", sequence: 1},
               actor: @system_actor
             )

    assert input_event.payload_text == nil
    assert input_event.redaction_reason == "input_recording_disabled"

    assert {:ok, output_event} =
             RemoteAccessRecordings.record_event(
               recording,
               %{
                 stream: :output,
                 event_type: "terminal_output",
                 data: "token=PVEAPIToken=very-secret\n",
                 sequence: 2
               },
               actor: @system_actor
             )

    assert output_event.payload_text == "REDACTED"
    assert output_event.payload_redacted == true
    assert output_event.redaction_reason == "credential_redaction"
    refute inspect(output_event) =~ "very-secret"

    assert {:error, :forbidden} =
             RemoteAccessRecordings.export(recording, actor: %{role: :viewer})

    assert {:ok, export} =
             RemoteAccessRecordings.export(recording,
               actor: %{role: :admin},
               audit_writer: AuditSink
             )

    assert export.manifest["export_event_count"] == 2
    assert export.manifest["export_contains_payload_text"] == true
    assert Enum.map(export.events, & &1.sequence) == [1, 2]

    assert_receive {:remote_access_audit, export_audit}
    assert export_audit[:action] == :remote_access_recording_exported
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

  defp insert_user!(label) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.insert_all("ng_users", [
      %{
        id: Ecto.UUID.dump!(id),
        email: "remote-access-#{label}-#{System.unique_integer([:positive])}@example.test",
        display_name: "Remote Access #{label}",
        role: "admin",
        inserted_at: now,
        updated_at: now
      }
    ])

    id
  end

  defp create_credential_rule!(suffix, attrs) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(:create, %{
        name: "remote-access-ssh-#{suffix}-#{System.unique_integer([:positive])}",
        provider: "ssh",
        credential_kind: :ssh_private_key,
        username: "root",
        secret_payload: private_key_fixture(),
        metadata: %{"auth_method" => "ssh_private_key"}
      })
      |> Ash.create(actor: @system_actor)

    {:ok, rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(:create, %{
        name: "remote-access-ssh-rule-#{System.unique_integer([:positive])}",
        provider: "ssh",
        auth_method: :ssh_private_key,
        purpose: :console_access,
        target_query: "in:devices",
        enabled: Keyword.get(attrs, :enabled, true),
        scope_type: Keyword.get(attrs, :scope_type, :agent),
        scope_value: Keyword.fetch!(attrs, :scope_value),
        secret_id: secret.id,
        allowed_ports: [22],
        ssh_host_key_policy: :known_hosts,
        metadata: Keyword.get(attrs, :metadata, %{})
      })
      |> Ash.create(actor: @system_actor)

    rule
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
