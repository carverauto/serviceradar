defmodule ServiceRadar.Edge.RemoteAccessSessionsTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.RemoteAccessCentralCredentialGrants
  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordingEvent
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadar.Edge.RemoteAccessRequests
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSessions
  alias ServiceRadar.Plugins.SecretRefs
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
  @principal "srp_v1_6d8b1e49fbe24ad487ce2c5c"
  @target_principal "srp_v1_91c5f16df8aa4d90a6db2ed7"

  setup do
    previous_policy =
      Application.get_env(:serviceradar_core, :remote_access_ssh_certificate_policy)

    previous_crypto_secret = Application.get_env(:serviceradar_core, :crypto_secret)

    Application.put_env(:serviceradar_core, :crypto_secret, String.duplicate("a", 32))

    Process.put(:remote_access_audit_owner, self())

    on_exit(fn ->
      if previous_crypto_secret do
        Application.put_env(:serviceradar_core, :crypto_secret, previous_crypto_secret)
      else
        Application.delete_env(:serviceradar_core, :crypto_secret)
      end

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

  test "falls back to the discovering sync service when the device has no owning agent" do
    uid = unique_uid("sync-scope")
    insert_device!(uid, metadata: %{"sync_service_id" => "agent-sync-scope"})

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{protocol: "ssh", credential_custody_mode: "user_present", cols: 120, rows: 40},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert session.agent_id == "agent-sync-scope"
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

    assert {:error, :current_authority_denied} =
             RemoteAccessSessions.attach_with_ticket(ticket,
               session_id: session.id,
               audit_writer: AuditSink
             )

    assert {:error, :current_authority_denied} =
             RemoteAccessSessions.attach_with_ticket(ticket,
               session_id: session.id,
               actor: %{id: Ecto.UUID.generate(), role: :viewer},
               trusted_internal_attach?: true,
               audit_writer: AuditSink
             )

    assert {:ok, %RemoteAccessSession{status: :attached}} =
             RemoteAccessSessions.attach_with_ticket(ticket,
               session_id: session.id,
               actor: @system_actor,
               trusted_internal_attach?: true,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, attach_audit}
    assert attach_audit[:action] == :remote_access_session_attach

    assert {:error, :invalid_or_expired_ticket} =
             RemoteAccessSessions.attach_with_ticket(ticket,
               session_id: session.id,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, attach_denial_audit}
    assert attach_denial_audit[:action] == :remote_access_session_attach_denied
    refute inspect(attach_denial_audit) =~ ticket
  end

  @tag sandbox: :unboxed
  test "attach ticket consume is atomic under concurrent replay" do
    uid = unique_uid("ticket-race")
    register_committed_race_cleanup!(device_uid: uid)
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

    results =
      run_committed_race!(
        """
        SELECT id
        FROM platform.remote_access_sessions
        WHERE id = $1::text::uuid
        FOR UPDATE
        """,
        [session.id],
        fn ->
          RemoteAccessSessions.attach_with_ticket(ticket,
            session_id: session.id,
            actor: @system_actor,
            trusted_internal_attach?: true,
            audit_writer: AuditSink
          )
        end
      )

    assert 1 ==
             Enum.count(results, fn
               {:ok, %RemoteAccessSession{status: :attached}} -> true
               _other -> false
             end)

    assert 3 == Enum.count(results, &(&1 == {:error, :invalid_or_expired_ticket}))

    audits =
      for _ <- 1..4 do
        assert_receive {:remote_access_audit, audit}, 1_000
        audit
      end

    assert 1 == Enum.count(audits, &(&1[:action] == :remote_access_session_attach))
    assert 3 == Enum.count(audits, &(&1[:action] == :remote_access_session_attach_denied))
    refute inspect(audits) =~ ticket
  end

  test "attach tickets are owner-bound and an ownership denial does not consume the ticket" do
    uid = unique_uid("ticket-owner")
    insert_device!(uid, agent_id: "agent-ticket-owner", gateway_id: "gateway-ticket-owner")
    owner_id = insert_user!("ticket-owner")

    assert {:ok, %{session: session, ticket: ticket}} =
             RemoteAccessSessions.request_open(
               uid,
               %{protocol: "ssh", credential_custody_mode: "user_present"},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}
    bind_session_owner!(session.id, owner_id)

    assert {:error, :invalid_or_expired_ticket} =
             RemoteAccessSessions.attach_with_ticket(ticket,
               session_id: session.id,
               scope: %{user: %{id: Ecto.UUID.generate()}},
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, attach_denied_audit}
    assert attach_denied_audit[:action] == :remote_access_session_attach_denied

    assert {:ok, %RemoteAccessSession{status: :attached}} =
             RemoteAccessSessions.attach_with_ticket(ticket,
               session_id: session.id,
               scope: %{user: %{id: owner_id}},
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, attach_audit}
    assert attach_audit[:action] == :remote_access_session_attach
  end

  test "browser lifecycle transitions and durable activity are owner-bound" do
    uid = unique_uid("lifecycle-owner")
    insert_device!(uid, agent_id: "agent-life-owner", gateway_id: "gateway-life-owner")
    owner_id = insert_user!("lifecycle-owner")
    owner_scope = %{user: %{id: owner_id}}
    other_scope = %{user: %{id: Ecto.UUID.generate()}}

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{credential_custody_mode: :user_present},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}
    bind_session_owner!(session.id, owner_id)

    assert {:error, :not_found} =
             RemoteAccessSessions.request_close(session.id,
               scope: other_scope,
               reason: "cross_user",
               audit_writer: AuditSink
             )

    assert {:ok, %RemoteAccessSession{status: :requested}} =
             RemoteAccessSession.get_by_id(session.id, actor: @system_actor)

    assert {:ok, %RemoteAccessSession{status: :opening}} =
             RemoteAccessSessions.mark_opening(session.id, audit_writer: AuditSink)

    assert_receive {:remote_access_audit, opening_audit}
    assert opening_audit[:action] == :remote_access_session_opening

    assert {:ok, %RemoteAccessSession{status: :active}} =
             RemoteAccessSessions.activate_session(session.id, audit_writer: AuditSink)

    assert_receive {:remote_access_audit, active_audit}
    assert active_audit[:action] == :remote_access_session_active

    old_activity = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

    Repo.query!(
      "UPDATE platform.remote_access_sessions SET last_activity_at = $2 WHERE id = $1::uuid",
      [Ecto.UUID.dump!(session.id), old_activity]
    )

    versions_before = version_count("remote_access_session_versions", session.id)

    assert {:error, :not_found} =
             RemoteAccessSessions.record_activity(session.id, scope: other_scope)

    assert {:ok, %RemoteAccessSession{last_activity_at: ^old_activity}} =
             RemoteAccessSession.get_by_id(session.id, actor: @system_actor)

    assert {:ok, %RemoteAccessSession{last_activity_at: refreshed_activity}} =
             RemoteAccessSessions.record_activity(session.id, scope: owner_scope)

    assert DateTime.after?(refreshed_activity, old_activity)
    assert version_count("remote_access_session_versions", session.id) == versions_before
    refute_receive {:remote_access_audit, %{action: :remote_access_session_activity}}, 50
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

  test "SSH certificate sessions require trusted account policy" do
    uid = unique_uid("ssh-cert-policy-required")
    insert_device!(uid, agent_id: "agent-policy-required", gateway_id: "gateway-policy-required")

    assert {:error, :ssh_principal_policy_required} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :ssh_certificate,
                 metadata: %{
                   "accounts" => [%{"name" => "root", "principals" => [@principal]}],
                   "ssh_accounts" => [
                     %{"name" => "mfreeman", "principals" => [@principal]}
                   ]
                 }
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "denied"
    assert denial_audit[:details][:failure_reason] == "ssh_principal_policy_required"
  end

  test "ssh_console_options returns account names without opaque principals" do
    uid = unique_uid("ssh-options")

    Application.put_env(:serviceradar_core, :remote_access_ssh_certificate_policy, %{
      "accounts" => [
        %{"name" => "mfreeman", "principals" => [@principal]},
        %{"name" => "deploy", "principals" => [@target_principal]}
      ],
      "ttl_seconds" => 900,
      "targets" => %{
        uid => %{
          "accounts" => [
            %{"name" => "mfreeman", "principals" => [@target_principal]}
          ],
          "ttl_seconds" => 600
        }
      }
    })

    insert_device!(uid, agent_id: "agent-options", gateway_id: "gateway-options")

    assert {:ok, options} = RemoteAccessSessions.ssh_console_options(uid)
    assert options["default_credential_mode"] == "ssh_certificate"
    assert options["ttl_seconds"] == 600
    assert options["device_uid"] == uid
    assert options["accounts"] == [%{"name" => "mfreeman"}]
    refute inspect(options) =~ "srp_v1_"
    refute inspect(options) =~ "principals"
  end

  test "ssh_console_options reports no accounts when the policy lists other targets only" do
    uid = unique_uid("ssh-options-unlisted")
    listed_uid = unique_uid("ssh-options-listed")

    # Shape of a real deployment policy: a per-target allow list that grants a
    # sibling host and no top-level `accounts` fallback. The unlisted device must
    # surface an empty account list so the console can say the target has no
    # certificate policy instead of offering a free-text account that can only
    # ever be refused at connect time.
    Application.put_env(:serviceradar_core, :remote_access_ssh_certificate_policy, %{
      "ttl_seconds" => 1800,
      "targets" => %{
        listed_uid => %{
          "accounts" => [%{"name" => "opsuser", "principals" => [@target_principal]}],
          "ttl_seconds" => 1800
        }
      }
    })

    insert_device!(uid, agent_id: "agent-unlisted", gateway_id: "gateway-unlisted")

    assert {:ok, options} = RemoteAccessSessions.ssh_console_options(uid)
    assert options["accounts"] == []
    assert options["device_uid"] == uid
    assert options["default_credential_mode"] == "ssh_certificate"

    assert {:error, :ssh_principal_policy_required} =
             RemoteAccessSessions.request_open(
               uid,
               %{protocol: :ssh, credential_custody_mode: :ssh_certificate},
               actor: @system_actor,
               audit_writer: AuditSink
             )
  end

  test "SSH certificate sessions materialize only trusted account policy from deployment config" do
    uid = unique_uid("ssh-cert-policy")

    Application.put_env(:serviceradar_core, :remote_access_ssh_certificate_policy, %{
      "accounts" => [%{"name" => "mfreeman", "principals" => [@principal]}],
      "principal_mappings" => [
        %{
          "source" => "groups",
          "value" => "linux-admins",
          "principals" => [@target_principal]
        }
      ],
      "ttl_seconds" => 900,
      "targets" => %{
        uid => %{
          "accounts" => [
            %{"name" => "mfreeman", "principals" => [@target_principal]}
          ],
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
                   "accounts" => [%{"name" => "root", "principals" => [@principal]}],
                   "ssh_accounts" => [%{"name" => "root", "principals" => [@principal]}],
                   "ssh_allowed_principals" => ["client-controlled"],
                   "ssh_certificate_ttl_seconds" => 28_800
                 }
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert session.metadata["safe"] == "kept"
    refute Map.has_key?(session.metadata, "accounts")
    refute Map.has_key?(session.metadata, "ssh_allowed_principals")

    assert session.metadata["ssh_accounts"] == [
             %{"name" => "mfreeman", "principals" => [@target_principal]}
           ]

    assert session.metadata["ssh_certificate_ttl_seconds"] == 600

    assert session.metadata["ssh_principal_mappings"] == [
             %{
               "source" => "groups",
               "value" => "linux-admins",
               "principals" => [@target_principal]
             }
           ]
  end

  test "SSH certificate sessions preserve malformed mappings for fail-closed issuance" do
    uid = unique_uid("ssh-cert-malformed-mapping")

    Application.put_env(:serviceradar_core, :remote_access_ssh_certificate_policy, %{
      "accounts" => [%{"name" => "mfreeman", "principals" => [@principal]}],
      "principal_mappings" => ["malformed-mapping"]
    })

    insert_device!(uid,
      agent_id: "agent-policy-malformed",
      gateway_id: "gateway-policy-malformed"
    )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{protocol: :ssh, credential_custody_mode: :ssh_certificate},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert session.metadata["ssh_principal_mappings"] == ["malformed-mapping"]
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
    assert broker["credential_secret_ref"] =~ "credentialref:network-credential-grant:"

    assert {:ok, rule.secret_id} ==
             SecretRefs.network_credential_ref_id(broker["credential_secret_ref"])

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

  @tag sandbox: :unboxed
  test "approved access request bind rolls back losing concurrent session creates" do
    suffix = System.unique_integer([:positive])
    uid = "remote-access-access-request-race-#{suffix}"
    agent_id = "agent-access-request-race-#{suffix}"
    gateway_id = "gateway-access-request-race-#{suffix}"
    credential_suffix = "access-request-race-#{suffix}"
    credential_secret_name = "remote-access-ssh-#{credential_suffix}"
    credential_rule_name = "remote-access-ssh-rule-#{credential_suffix}"
    requester_id = Ecto.UUID.generate()
    requester_profile_id = Ecto.UUID.generate()
    reviewer_id = Ecto.UUID.generate()
    reviewer_profile_id = Ecto.UUID.generate()

    register_committed_race_cleanup!(
      device_uid: uid,
      credential_secret_name: credential_secret_name,
      credential_rule_name: credential_rule_name,
      user_ids: [requester_id, reviewer_id],
      role_profile_ids: [requester_profile_id, reviewer_profile_id]
    )

    insert_device!(uid,
      agent_id: agent_id,
      gateway_id: gateway_id
    )

    credential_rule_id =
      create_credential_rule!(credential_suffix,
        scope_value: agent_id,
        secret_name: credential_secret_name,
        rule_name: credential_rule_name
      ).id

    ^requester_id =
      insert_user!("race-requester-#{suffix}",
        id: requester_id,
        profile_id: requester_profile_id
      )

    ^reviewer_id =
      insert_user!("race-reviewer-#{suffix}", id: reviewer_id, profile_id: reviewer_profile_id)

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
                 agent_id: agent_id,
                 gateway_id: gateway_id,
                 credential_custody_mode: :centrally_brokered,
                 credential_rule_id: credential_rule_id,
                 reason: "race maintenance",
                 ttl_seconds: 600
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, request_audit}
    assert request_audit[:action] == :remote_access_request_created

    assert {:ok, approved} =
             RemoteAccessRequests.approve(access_request,
               actor: %{id: reviewer_id, role: :system, email: "race-reviewer@example.test"},
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, approval_audit}
    assert approval_audit[:action] == :remote_access_request_approved

    results =
      run_committed_race!(
        """
        SELECT id
        FROM platform.remote_access_requests
        WHERE id = $1::text::uuid
        FOR UPDATE
        """,
        [approved.id],
        fn ->
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
      )

    successes =
      Enum.filter(results, fn
        {:ok, %{session: %RemoteAccessSession{}}} -> true
        _other -> false
      end)

    assert [%{session: winning_session}] = Enum.map(successes, fn {:ok, result} -> result end)
    assert 3 == Enum.count(results, &(&1 == {:error, :approval_consumed}))

    assert {:ok, consumed} = RemoteAccessRequests.get(approved.id, actor: @system_actor)
    assert consumed.status == :consumed
    assert consumed.session_id == winning_session.id

    assert %Postgrex.Result{rows: [[1]]} =
             Repo.query!(
               """
               SELECT count(*)
               FROM platform.remote_access_sessions
               WHERE approval_id = $1::text::uuid
               """,
               [approved.id]
             )

    audits =
      for _ <- 1..5 do
        assert_receive {:remote_access_audit, audit}, 1_000
        audit
      end

    assert 1 == Enum.count(audits, &(&1[:action] == :remote_access_request_consumed))
    assert 1 == Enum.count(audits, &(&1[:action] == :remote_access_session_create))
    assert 3 == Enum.count(audits, &(&1[:action] == :remote_access_session_denied))
  end

  test "PaperTrail action inputs do not retain credential pointers" do
    uid = unique_uid("papertrail")
    insert_device!(uid, agent_id: "agent-papertrail", gateway_id: "gateway-papertrail")

    credential_rule_id =
      create_credential_rule!("papertrail", scope_value: "agent-papertrail").id

    requester_id = insert_user!("papertrail-requester")
    reviewer_id = insert_user!("papertrail-reviewer")

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
                 agent_id: "agent-papertrail",
                 gateway_id: "gateway-papertrail",
                 credential_custody_mode: :centrally_brokered,
                 credential_rule_id: credential_rule_id,
                 reason: "papertrail hardening",
                 ttl_seconds: 600,
                 metadata: %{"private_key" => private_key_fixture(), "safe" => "kept"}
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, request_audit}
    assert request_audit[:action] == :remote_access_request_created

    assert {:ok, approved} =
             RemoteAccessRequests.approve(access_request,
               actor: %{id: reviewer_id, role: :system, email: "papertrail-reviewer@example.test"},
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, approval_audit}
    assert approval_audit[:action] == :remote_access_request_approved

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :centrally_brokered,
                 approval_id: approved.id,
                 credential_rule_id: credential_rule_id,
                 metadata: %{"private_key" => private_key_fixture(), "safe" => "kept"}
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, consumed_audit}
    assert consumed_audit[:action] == :remote_access_request_consumed
    assert_receive {:remote_access_audit, create_audit}
    assert create_audit[:action] == :remote_access_session_create

    request_action_inputs = version_action_inputs("remote_access_request_versions", approved.id)
    session_action_inputs = version_action_inputs("remote_access_session_versions", session.id)

    assert request_action_inputs != []
    assert session_action_inputs != []
    assert Enum.all?(request_action_inputs, &blank_action_inputs?/1)
    assert Enum.all?(session_action_inputs, &blank_action_inputs?/1)
    refute inspect(request_action_inputs) =~ credential_rule_id
    refute inspect(session_action_inputs) =~ credential_rule_id
    refute inspect(session_action_inputs) =~ approved.id
    refute inspect(request_action_inputs) =~ "private_key"
    refute inspect(session_action_inputs) =~ "private_key"

    assert version_count("remote_access_request_versions", approved.id) > 0
    assert version_count("remote_access_session_versions", session.id) > 0

    Repo.query!("DELETE FROM platform.remote_access_requests WHERE id = $1::text::uuid", [
      approved.id
    ])

    Repo.query!("DELETE FROM platform.remote_access_sessions WHERE id = $1::text::uuid", [
      session.id
    ])

    assert version_count("remote_access_request_versions", approved.id) == 0
    assert version_count("remote_access_session_versions", session.id) == 0
  end

  test "RDP approvals are scoped to the selected desktop target and agent route" do
    uid = unique_uid("rdp-approval")
    insert_device!(uid, agent_id: "agent-rdp-approval", gateway_id: "gateway-rdp-approval")

    requester_id = insert_user!("rdp-requester")
    reviewer_id = insert_user!("rdp-reviewer")
    requester_actor = %{id: requester_id, role: :system, email: "rdp-requester@example.test"}

    request_attrs = %{
      requested_by: requester_id,
      device_uid: uid,
      target_kind: :inventory_device,
      target_host: "winhost.example.test",
      target_port: 3389,
      protocol: :rdp,
      adapter: :rdp,
      agent_id: "agent-rdp-approval",
      gateway_id: "gateway-rdp-approval",
      credential_custody_mode: :user_present,
      reason: "desktop maintenance",
      ttl_seconds: 600,
      metadata: %{
        "desktop_target_id" => "desktop-target-rdp-1",
        "route_policy" => %{"gateway_id" => "gateway-rdp-approval"},
        "redirection_policy" => %{"clipboard" => "disabled", "drive" => "disabled"}
      }
    }

    assert {:ok, access_request} =
             RemoteAccessRequests.create(request_attrs,
               actor: requester_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, create_request_audit}
    assert create_request_audit[:action] == :remote_access_request_created

    assert {:ok, approved} =
             RemoteAccessRequests.approve(access_request,
               actor: %{id: reviewer_id, role: :system, email: "rdp-reviewer@example.test"},
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, approve_request_audit}
    assert approve_request_audit[:action] == :remote_access_request_approved

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :rdp,
                 adapter: :rdp,
                 target_host: "winhost.example.test",
                 target_port: 3389,
                 credential_custody_mode: :user_present,
                 approval_required: true,
                 approval_id: approved.id,
                 metadata: %{
                   "desktop_target_id" => "desktop-target-rdp-1",
                   "route_policy" => %{"gateway_id" => "gateway-rdp-approval"},
                   "redirection_policy" => %{"clipboard" => "disabled", "drive" => "disabled"}
                 }
               },
               actor: requester_actor,
               audit_writer: AuditSink
             )

    assert session.protocol == :rdp
    assert session.adapter == :rdp
    assert session.approval_id == approved.id
    assert session.target_host == "winhost.example.test"
    assert session.target_port == 3389
    assert session.agent_id == "agent-rdp-approval"
    assert session.gateway_id == "gateway-rdp-approval"
    assert session.metadata["desktop_target_id"] == "desktop-target-rdp-1"
    assert session.metadata["route_policy"] == %{"gateway_id" => "gateway-rdp-approval"}

    assert session.metadata["redirection_policy"] == %{
             "clipboard" => "disabled",
             "drive" => "disabled"
           }

    assert_receive {:remote_access_audit, consume_request_audit}
    assert consume_request_audit[:action] == :remote_access_request_consumed
    assert_receive {:remote_access_audit, create_session_audit}
    assert create_session_audit[:action] == :remote_access_session_create

    assert {:ok, consumed} = RemoteAccessRequests.get(approved.id, actor: @system_actor)
    assert consumed.status == :consumed
    assert consumed.session_id == session.id

    assert {:ok, mismatched_request} =
             RemoteAccessRequests.create(
               %{
                 request_attrs
                 | metadata: %{
                     "desktop_target_id" => "desktop-target-rdp-1",
                     "route_policy" => %{"gateway_id" => "gateway-rdp-approval"},
                     "redirection_policy" => %{"clipboard" => "enabled", "drive" => "disabled"}
                   }
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, create_mismatch_request_audit}
    assert create_mismatch_request_audit[:action] == :remote_access_request_created

    assert {:ok, mismatched_approved} =
             RemoteAccessRequests.approve(mismatched_request,
               actor: %{id: reviewer_id, role: :system, email: "rdp-reviewer@example.test"},
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, approve_mismatch_request_audit}
    assert approve_mismatch_request_audit[:action] == :remote_access_request_approved

    assert {:error, :approval_scope_mismatch} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :rdp,
                 adapter: :rdp,
                 target_host: "winhost.example.test",
                 target_port: 3389,
                 credential_custody_mode: :user_present,
                 approval_required: true,
                 approval_id: mismatched_approved.id,
                 metadata: %{
                   "desktop_target_id" => "desktop-target-rdp-1",
                   "route_policy" => %{"gateway_id" => "gateway-rdp-approval"},
                   "redirection_policy" => %{"clipboard" => "disabled", "drive" => "disabled"}
                 }
               },
               actor: requester_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, denial_audit}
    assert denial_audit[:action] == :remote_access_session_denied
    assert denial_audit[:details][:rbac_decision] == "approval_scope_mismatch"

    assert {:ok, still_approved} =
             RemoteAccessRequests.get(mismatched_approved.id, actor: @system_actor)

    assert still_approved.status == :approved
    assert is_nil(still_approved.session_id)
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

  test "an inventory-device session dials the device address rather than its hostname" do
    uid = unique_uid("dial-target")

    insert_device!(uid,
      agent_id: "agent-dial-target",
      gateway_id: "gateway-dial-target",
      hostname: "host01",
      ip: "192.0.2.10"
    )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{protocol: :ssh, credential_custody_mode: :user_present},
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}

    assert session.target_host == "192.0.2.10"
    assert session.metadata["target"]["hostname"] == "host01"
    assert session.metadata["target"]["ip"] == "192.0.2.10"
  end

  test "an operator-supplied target host still overrides the device address" do
    uid = unique_uid("dial-target-override")

    insert_device!(uid,
      agent_id: "agent-dial-override",
      gateway_id: "gateway-dial-override",
      hostname: "host01",
      ip: "192.0.2.10"
    )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :user_present,
                 target_host: "jump01.example.com"
               },
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, _create_audit}

    assert session.target_host == "jump01.example.com"
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
    assert recording.manifest["credential_custody_mode"] == "user_present"
    assert recording.manifest["rbac_decision"] == "allowed"
    assert recording.manifest["idle_timeout_seconds"] == 900
    assert recording.manifest["absolute_timeout_seconds"] == 3600

    assert recording.manifest["redaction_policy"]["credential_redactor"] ==
             "serviceradar_credential_redactor_v1"

    assert recording.manifest["redaction_policy"]["decision_time"] == "record_time"
    assert recording.manifest["redaction_policy"]["policy_edits_retroactive"] == false
    assert recording.manifest["redaction_policy"]["terminal_payloads_allowed"] == false
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

    assert {:ok, %RemoteAccessRecordingEvent{}} =
             RemoteAccessRecordings.record_event(
               active,
               %{stream: :input, event_type: "terminal_input", data: "whoami\n", sequence: 1},
               actor: @system_actor
             )

    assert {:ok, %RemoteAccessRecordingEvent{}} =
             RemoteAccessRecordings.record_event(
               active,
               %{stream: :output, event_type: "terminal_output", data: "root\n", sequence: 2},
               actor: @system_actor
             )

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
    refute inspect(completed) =~ "whoami\\n"
    refute inspect(completed) =~ "root\\n"

    assert_receive {:remote_access_audit, recording_complete_audit}
    assert recording_complete_audit[:action] == :remote_access_recording_completed
    assert recording_complete_audit[:details][:input_bytes] == 7
    assert recording_complete_audit[:details][:output_bytes] == 5
    assert recording_complete_audit[:details][:event_count] == 2

    assert {:ok, fetched} = RemoteAccessRecording.get_by_session(session.id, actor: @system_actor)
    assert fetched.id == completed.id
  end

  test "recording completion uses the create-time policy snapshot" do
    uid = unique_uid("recording-policy-snapshot")

    insert_device!(uid,
      agent_id: "agent-recording-policy-snapshot",
      gateway_id: "gateway-recording"
    )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :user_present,
                 recording_policy: %{
                   "enabled" => true,
                   "mode" => "metadata",
                   "record_terminal_payloads" => false,
                   "retention_days" => 7
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

    mutated =
      Map.put(recording, :policy, %{"enabled" => true, "record_terminal_payloads" => true})

    assert {:ok, completed} =
             RemoteAccessRecordings.complete(
               mutated,
               %{input_bytes: 0, output_bytes: 0, event_count: 0},
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert completed.manifest["policy"]["record_terminal_payloads"] == false
    assert completed.manifest["raw_terminal_payloads_stored"] == false
  end

  test "recording events cannot be appended after seal even with a stale recording struct" do
    uid = unique_uid("recording-event-seal")

    insert_device!(uid,
      agent_id: "agent-recording-event-seal",
      gateway_id: "gateway-recording"
    )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :user_present,
                 recording_policy: %{
                   "enabled" => true,
                   "mode" => "metadata",
                   "retention_days" => 7
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

    assert {:ok, %RemoteAccessRecordingEvent{}} =
             RemoteAccessRecordings.record_event(
               recording,
               %{stream: :output, event_type: "terminal_output", data: "first\n", sequence: 1},
               actor: @system_actor
             )

    assert {:ok, %RemoteAccessRecording{status: :completed}} =
             RemoteAccessRecordings.complete(
               recording,
               %{input_bytes: 0, output_bytes: 6, event_count: 1},
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert {:error, :recording_sealed} =
             RemoteAccessRecordings.record_event(
               recording,
               %{stream: :output, event_type: "terminal_output", data: "late\n", sequence: 2},
               actor: @system_actor
             )

    assert {:ok, events} = RemoteAccessRecordings.list_events(recording, actor: @system_actor)
    assert Enum.map(events, & &1.sequence) == [1]
  end

  test "recording completion refuses a manifest count that does not match persisted events" do
    uid = unique_uid("recording-count-mismatch")

    insert_device!(uid,
      agent_id: "agent-recording-count-mismatch",
      gateway_id: "gateway-recording"
    )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :user_present,
                 recording_policy: %{
                   "enabled" => true,
                   "mode" => "metadata",
                   "retention_days" => 7
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

    assert {:ok, %RemoteAccessRecordingEvent{}} =
             RemoteAccessRecordings.record_event(
               recording,
               %{stream: :output, event_type: "terminal_output", data: "first\n", sequence: 1},
               actor: @system_actor
             )

    assert {:error, :recording_event_count_mismatch} =
             RemoteAccessRecordings.complete(
               recording,
               %{input_bytes: 0, output_bytes: 6, event_count: 2},
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert {:ok, %RemoteAccessRecording{status: :pending}} =
             RemoteAccessRecording.get_by_id(recording.id, actor: @system_actor)

    assert {:ok, %RemoteAccessRecording{status: :completed}} =
             RemoteAccessRecordings.complete(
               recording,
               %{input_bytes: 0, output_bytes: 6, event_count: 1},
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )
  end

  test "stale active recordings are expired with actual persisted event counters" do
    uid = unique_uid("recording-stale-expire")

    insert_device!(uid,
      agent_id: "agent-recording-stale-expire",
      gateway_id: "gateway-recording"
    )

    assert {:ok, %{session: session}} =
             RemoteAccessSessions.request_open(
               uid,
               %{
                 protocol: :ssh,
                 credential_custody_mode: :user_present,
                 recording_policy: %{
                   "enabled" => true,
                   "mode" => "metadata",
                   "retention_days" => 7
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

    assert {:ok, %RemoteAccessRecording{} = active} =
             RemoteAccessRecordings.activate(recording,
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert_receive {:remote_access_audit, _recording_create_audit}
    assert_receive {:remote_access_audit, _recording_active_audit}

    assert {:ok, %RemoteAccessRecordingEvent{} = event} =
             RemoteAccessRecordings.record_event(
               active,
               %{stream: :output, event_type: "terminal_output", data: "stale\n", sequence: 1},
               actor: @system_actor
             )

    stale_at = DateTime.add(DateTime.utc_now(), -7_200, :second)

    assert {:ok, _result} =
             Repo.query(
               "UPDATE platform.remote_access_recordings SET inserted_at = $2, updated_at = $2 WHERE id = $1::uuid",
               [Ecto.UUID.dump!(active.id), stale_at]
             )

    assert {:ok, _result} =
             Repo.query(
               "UPDATE platform.remote_access_recording_events SET inserted_at = $2, updated_at = $2 WHERE id = $1::uuid",
               [Ecto.UUID.dump!(event.id), stale_at]
             )

    assert {:ok, 1} =
             RemoteAccessRecordings.expire_stale(
               stale_after_seconds: 3_600,
               batch_size: 10,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_audit, expired_audit}
    assert expired_audit[:action] == :remote_access_recording_expired

    assert {:ok, %RemoteAccessRecording{status: :expired} = expired} =
             RemoteAccessRecording.get_by_id(active.id, actor: @system_actor)

    assert expired.event_count == 1
    assert expired.output_bytes == byte_size("stale\n")
    assert expired.manifest["event_count"] == 1
    assert expired.manifest["manifest_integrity_status"] == nil
    assert expired.manifest["integrity"]["algorithm"] == "hmac-sha256-v1"
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

    assert {:ok, %{rows: [[raw_manifest, encrypted_manifest]]}} =
             Repo.query(
               "SELECT manifest::text, encrypted_manifest FROM platform.remote_access_recordings WHERE id = $1::uuid",
               [Ecto.UUID.dump!(recording.id)]
             )

    refute raw_manifest =~ "agent-recording-content"
    assert is_binary(encrypted_manifest)
    refute encrypted_manifest =~ "agent-recording-content"

    assert {:ok, input_event} =
             RemoteAccessRecordings.record_event(
               recording,
               %{stream: :input, event_type: "terminal_input", data: "whoami\n", sequence: 1},
               actor: @system_actor
             )

    assert input_event.payload_text == nil
    assert input_event.redaction_reason == "input_recording_disabled"
    assert input_event.prior_event_hash == nil

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

    assert output_event.prior_event_hash ==
             RemoteAccessRecordings.event_integrity_hash(input_event)

    refute inspect(output_event) =~ "very-secret"

    assert {:ok, %{rows: [[raw_payload, encrypted_payload]]}} =
             Repo.query(
               "SELECT payload_text, encrypted_payload_text FROM platform.remote_access_recording_events WHERE id = $1::uuid",
               [Ecto.UUID.dump!(output_event.id)]
             )

    assert raw_payload == nil
    assert is_binary(encrypted_payload)
    refute encrypted_payload =~ "REDACTED"
    refute encrypted_payload =~ "very-secret"

    assert {:ok, %RemoteAccessRecording{status: :completed} = completed} =
             RemoteAccessRecordings.complete(
               recording,
               %{
                 input_bytes: input_event.byte_count,
                 output_bytes: output_event.byte_count,
                 event_count: 2
               },
               audit_writer: AuditSink,
               audit_actor: @system_actor
             )

    assert_receive {:remote_access_audit, completed_audit}
    assert completed_audit[:action] == :remote_access_recording_completed

    assert {:error, :forbidden} =
             RemoteAccessRecordings.export(completed, actor: %{role: :viewer})

    assert {:ok, export} =
             RemoteAccessRecordings.export(completed,
               actor: %{role: :admin},
               audit_writer: AuditSink
             )

    assert export.manifest["export_event_count"] == 2
    assert export.manifest["export_id"] == export.export_id
    assert {:ok, _export_uuid} = Ecto.UUID.cast(export.export_id)
    assert export.manifest["export_contains_payload_text"] == true
    assert export.manifest["event_chain_verified"] == true

    assert export.manifest["event_chain_root"] ==
             RemoteAccessRecordings.event_integrity_hash(output_event)

    assert export.manifest["manifest_integrity_verified"] == true
    assert export.manifest["manifest_integrity_status"] == "verified"
    assert export.manifest["integrity"]["algorithm"] == "hmac-sha256-v1"
    assert is_binary(export.manifest["integrity"]["signature"])

    assert Enum.map(export.events, & &1.sequence) == [1, 2]

    assert_receive {:remote_access_audit, export_audit}
    assert export_audit[:action] == :remote_access_recording_exported
    assert export_audit[:details][:export_id] == export.export_id

    tampered_manifest =
      update_in(completed.manifest, ["integrity", "event_chain_root"], fn _root -> "tampered" end)

    tampered_encrypted_manifest = AshCloak.do_encrypt(RemoteAccessRecording, tampered_manifest)

    assert {:ok, _result} =
             Repo.query(
               "UPDATE platform.remote_access_recordings SET encrypted_manifest = $2 WHERE id = $1::uuid",
               [Ecto.UUID.dump!(completed.id), tampered_encrypted_manifest]
             )

    assert {:error, :recording_manifest_integrity_check_failed} =
             RemoteAccessRecordings.export(completed, actor: %{role: :admin})
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

  defp run_committed_race!(lock_sql, lock_params, operation)
       when is_binary(lock_sql) and is_list(lock_params) and is_function(operation, 0) do
    parent = self()
    race_ref = make_ref()
    race_deadline = System.monotonic_time(:millisecond) + 45_000
    remaining_timeout = fn -> max(race_deadline - System.monotonic_time(:millisecond), 0) end

    # The holder keeps the target row unavailable until all four racers prove they are
    # concurrently waiting. Racers use checkout, not an enclosing transaction, so the
    # application transactions under test retain their real commit/rollback behavior.
    lock_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert %Postgrex.Result{num_rows: 1} = Repo.query!(lock_sql, lock_params)
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:committed_race_lock_held, race_ref, self(), backend_pid})

          receive do
            {:release_committed_race_lock, ^race_ref} -> :ok
          after
            remaining_timeout.() -> raise "timed out waiting to release committed race lock"
          end
        end)
      end)

    try do
      assert_receive {:committed_race_lock_held, ^race_ref, lock_holder_pid,
                      lock_holder_backend_pid},
                     remaining_timeout.()

      assert lock_holder_pid == lock_holder.pid

      racers =
        for _attempt <- 1..4 do
          Task.async(fn ->
            Repo.checkout(
              fn ->
                [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
                send(parent, {:committed_race_ready, race_ref, self(), backend_pid})

                receive do
                  {:run_committed_race, ^race_ref} -> :ok
                after
                  remaining_timeout.() -> raise "timed out waiting to start committed race"
                end

                Process.put(:remote_access_audit_owner, parent)
                operation.()
              end,
              timeout: remaining_timeout.()
            )
          end)
        end

      try do
        ready =
          for _racer <- racers do
            assert_receive {:committed_race_ready, ^race_ref, racer_pid, backend_pid},
                           remaining_timeout.()

            {racer_pid, backend_pid}
          end

        assert MapSet.new(Enum.map(ready, &elem(&1, 0))) ==
                 MapSet.new(Enum.map(racers, & &1.pid))

        racer_backend_pids = Enum.map(ready, &elem(&1, 1))
        assert 4 == racer_backend_pids |> MapSet.new() |> MapSet.size()
        refute lock_holder_backend_pid in racer_backend_pids

        Enum.each(racers, &send(&1.pid, {:run_committed_race, race_ref}))
        assert :ok = await_racers_waiting_on_locks(racer_backend_pids, race_deadline)

        send(lock_holder.pid, {:release_committed_race_lock, race_ref})
        assert {:ok, :ok} = Task.await(lock_holder, remaining_timeout.())

        Enum.map(racers, &Task.await(&1, remaining_timeout.()))
      after
        Enum.each(racers, fn racer ->
          if Process.alive?(racer.pid), do: Task.shutdown(racer, :brutal_kill)
        end)
      end
    after
      if Process.alive?(lock_holder.pid) do
        send(lock_holder.pid, {:release_committed_race_lock, race_ref})

        if is_nil(Task.yield(lock_holder, 1_000)) do
          Task.shutdown(lock_holder, :brutal_kill)
        end
      end
    end
  end

  defp await_racers_waiting_on_locks(backend_pids, deadline) do
    waiting_backend_pids =
      MapSet.new(
        Repo.query!(
          """
          SELECT pid
          FROM pg_stat_activity
          WHERE datname = current_database()
            AND pid = ANY($1::int[])
            AND state = 'active'
            AND wait_event_type = 'Lock'
            AND cardinality(pg_blocking_pids(pid)) > 0
          """,
          [backend_pids]
        ).rows,
        &List.first/1
      )

    expected_backend_pids = MapSet.new(backend_pids)

    cond do
      MapSet.equal?(waiting_backend_pids, expected_backend_pids) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "expected all race backends #{inspect(expected_backend_pids)} to wait on locks, " <>
            "observed #{inspect(waiting_backend_pids)}"
        )

      true ->
        Process.sleep(10)
        await_racers_waiting_on_locks(backend_pids, deadline)
    end
  end

  defp register_committed_race_cleanup!(opts) do
    device_uid = Keyword.fetch!(opts, :device_uid)
    credential_rule_name = Keyword.get(opts, :credential_rule_name)
    credential_secret_name = Keyword.get(opts, :credential_secret_name)
    user_ids = Keyword.get(opts, :user_ids, [])
    role_profile_ids = Keyword.get(opts, :role_profile_ids, [])

    on_exit(fn ->
      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Repo.query!(
                   "DELETE FROM platform.remote_access_requests WHERE device_uid = $1",
                   [device_uid]
                 )

                 Repo.query!(
                   "DELETE FROM platform.remote_access_sessions WHERE device_uid = $1",
                   [device_uid]
                 )

                 if is_binary(credential_rule_name) do
                   Repo.query!(
                     """
                     DELETE FROM platform.network_credential_rule_versions
                     WHERE version_source_id IN (
                       SELECT id
                       FROM platform.network_credential_rules
                       WHERE provider = 'ssh' AND name = $1
                     )
                     """,
                     [credential_rule_name]
                   )

                   Repo.query!(
                     "DELETE FROM platform.network_credential_rules WHERE provider = 'ssh' AND name = $1",
                     [credential_rule_name]
                   )
                 end

                 if is_binary(credential_secret_name) do
                   Repo.query!(
                     """
                     DELETE FROM platform.network_credential_secret_versions
                     WHERE version_source_id IN (
                       SELECT id
                       FROM platform.network_credential_secrets
                       WHERE provider = 'ssh' AND name = $1
                     )
                     """,
                     [credential_secret_name]
                   )

                   Repo.query!(
                     "DELETE FROM platform.network_credential_secrets WHERE provider = 'ssh' AND name = $1",
                     [credential_secret_name]
                   )
                 end

                 Enum.each(user_ids, fn user_id ->
                   Repo.query!("DELETE FROM platform.ng_users WHERE id = $1::text::uuid", [
                     user_id
                   ])
                 end)

                 Enum.each(role_profile_ids, fn profile_id ->
                   Repo.query!("DELETE FROM platform.role_profiles WHERE id = $1::text::uuid", [
                     profile_id
                   ])
                 end)

                 Repo.query!("DELETE FROM platform.ocsf_devices WHERE uid = $1", [device_uid])
                 :ok
               end)
    end)
  end

  defp insert_device!(uid, opts) do
    now = DateTime.utc_now()

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: Keyword.get(opts, :hostname, uid),
        ip: Keyword.get(opts, :ip),
        vendor_name: "Linux",
        agent_id: Keyword.get(opts, :agent_id),
        gateway_id: Keyword.get(opts, :gateway_id),
        is_available: true,
        metadata: Keyword.get(opts, :metadata, %{}),
        first_seen_time: now,
        last_seen_time: now
      }
    ])
  end

  defp insert_user!(label, opts \\ []) do
    id = Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0)
    profile_id = Keyword.get_lazy(opts, :profile_id, &Ecto.UUID.generate/0)
    now = DateTime.utc_now()

    Repo.insert_all("role_profiles", [
      %{
        id: Ecto.UUID.dump!(profile_id),
        system_name: nil,
        name: "Remote Access Test #{label} #{System.unique_integer([:positive])}",
        description: "Persistence-backed authority for remote access tests",
        permissions: [
          "devices.remote_access.ssh.open",
          "devices.remote_access.rdp.open"
        ],
        system: false,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("ng_users", [
      %{
        id: Ecto.UUID.dump!(id),
        email: "remote-access-#{label}-#{System.unique_integer([:positive])}@example.test",
        display_name: "Remote Access #{label}",
        role: "admin",
        role_profile_id: Ecto.UUID.dump!(profile_id),
        inserted_at: now,
        updated_at: now
      }
    ])

    id
  end

  defp bind_session_owner!(session_id, owner_id) do
    Repo.query!(
      "UPDATE platform.remote_access_sessions SET requested_by = $2::uuid WHERE id = $1::uuid",
      [Ecto.UUID.dump!(session_id), Ecto.UUID.dump!(owner_id)]
    )
  end

  defp create_credential_rule!(suffix, attrs) do
    secret_name =
      Keyword.get_lazy(attrs, :secret_name, fn ->
        "remote-access-ssh-#{suffix}-#{System.unique_integer([:positive])}"
      end)

    rule_name =
      Keyword.get_lazy(attrs, :rule_name, fn ->
        "remote-access-ssh-rule-#{System.unique_integer([:positive])}"
      end)

    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(:create, %{
        name: secret_name,
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
        name: rule_name,
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

  defp blank_action_inputs?(nil), do: true
  defp blank_action_inputs?(%{} = inputs), do: map_size(inputs) == 0
  defp blank_action_inputs?(_inputs), do: false

  defp version_action_inputs(table, source_id)
       when table in ["remote_access_request_versions", "remote_access_session_versions"] do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT version_action_inputs
        FROM platform.#{table}
        WHERE version_source_id = $1::text::uuid
        ORDER BY version_inserted_at ASC
        """,
        [source_id]
      )

    Enum.map(rows, fn [action_inputs] -> action_inputs end)
  end

  defp version_count(table, source_id)
       when table in ["remote_access_request_versions", "remote_access_session_versions"] do
    %Postgrex.Result{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(*)
        FROM platform.#{table}
        WHERE version_source_id = $1::text::uuid
        """,
        [source_id]
      )

    count
  end

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
