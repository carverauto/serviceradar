defmodule ServiceRadar.Automation.CallbackGrants.AshStoreDbTest do
  use ServiceRadar.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.CallbackGrants.AshStore
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.Callbacks.AuditEvent
  alias ServiceRadar.Automation.Callbacks.Grant
  alias ServiceRadar.Automation.Callbacks.Use
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration
  @actor SystemActor.system(:automation_callback_grant_store_db_test)

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    ids = dependency_ids()
    insert_dependencies(ids)
    %{ids: ids, grant: pure_grant(ids)}
  end

  test "persists pending before credential binding and atomically consumes/replays", context do
    assert {:ok, pending} = AshStore.create_pending(context.grant, %{}, nil)
    assert pending.id == context.grant.id
    assert pending.state == :pending
    assert pending.ephemeral_credential_id == nil

    assert {:ok, stored_pending} = Grant.get_by_id(pending.id, actor: @actor)
    assert stored_pending.state == :pending
    assert stored_pending.awx_ephemeral_credential_id == nil
    assert stored_pending.credential_cleanup_state == :not_created

    assert {:ok, events} = AuditEvent.list_for_grant(pending.id, actor: @actor)
    assert Enum.map(events, & &1.event_type) == [:mint_pending]

    authorize = fn locked ->
      assert locked.state == :pending
      assert locked.ephemeral_credential_id == nil
      :ok
    end

    assert {:ok, :bound, bound} =
             AshStore.bind_credential(pending.id, 31, authorize, %{}, DateTime.utc_now(), nil)

    assert bound.state == :pending
    assert bound.ephemeral_credential_id == 31

    binding =
      context.grant.awx_scope_snapshot
      |> Map.update!(:credential_ids, &(&1 ++ [31]))
      |> Map.put(:job_id, 9_001)

    assert {:ok, :activated, active} =
             AshStore.activate(
               pending.id,
               binding,
               fn locked ->
                 assert locked.ephemeral_credential_id == 31
                 :ok
               end,
               %{},
               DateTime.utc_now(),
               nil
             )

    assert active.state == :active
    assert Enum.sort(active.job_binding["credential_ids"]) == [5, 31]

    response = ~s({"action":"remote_access.ssh_ca.bundle.read","ok":true})
    attrs = consume_attrs(response)

    assert {:ok, :committed, ^response, consumed} =
             AshStore.consume_once(
               pending.id,
               attrs,
               response,
               fn locked ->
                 assert locked.state == :active
                 :ok
               end,
               %{},
               DateTime.utc_now(),
               nil
             )

    assert consumed.state == :consumed
    assert consumed.budget_remaining == 0

    assert {:ok, use} =
             Use.get_by_idempotency_verifier(
               pending.id,
               attrs.idempotency_key_verifier,
               actor: @actor
             )

    assert use.state == :committed
    assert use.response_bytes == response
    assert use.response_reference == nil
    assert use.response_fingerprint == CanonicalJSON.sha256(response)

    assert {:ok, :replay, ^response, replay_grant} =
             AshStore.consume_once(
               pending.id,
               attrs,
               response,
               fn locked ->
                 assert locked.state == :consumed
                 :ok
               end,
               %{},
               DateTime.utc_now(),
               nil
             )

    assert replay_grant.state == :consumed

    assert {:ok, events} = AuditEvent.list_for_grant(pending.id, actor: @actor)

    assert Enum.map(events, & &1.event_type) == [
             :mint_pending,
             :credential_created,
             :binding_activated,
             :callback_allowed,
             :callback_replay
           ]

    changed_request = %{attrs | request_digest: String.duplicate("9", 64)}

    assert {:error, :idempotency_payload_conflict} =
             AshStore.consume_once(
               pending.id,
               changed_request,
               response,
               fn _locked -> :ok end,
               %{},
               DateTime.utc_now(),
               nil
             )

    different_key = %{attrs | idempotency_key_verifier: <<8::256>>}

    assert {:error, :invalid_idempotency_key} =
             AshStore.consume_once(
               pending.id,
               different_key,
               response,
               fn _locked -> :ok end,
               %{},
               DateTime.utc_now(),
               nil
             )

    assert {:error, :current_authority_revoked} =
             AshStore.consume_once(
               pending.id,
               attrs,
               response,
               fn _locked -> {:error, :current_authority_revoked} end,
               %{},
               DateTime.utc_now(),
               nil
             )

    assert {:ok, uses} = Use.list_for_grant(pending.id, actor: @actor)
    assert length(uses) == 1
  end

  test "revoked authority without an accepted AWX job has no cancellation risk", context do
    {:ok, pending} = AshStore.create_pending(context.grant, %{}, nil)

    assert {:ok, :bound, _bound} =
             AshStore.bind_credential(
               pending.id,
               31,
               fn _locked -> :ok end,
               %{},
               DateTime.utc_now(),
               nil
             )

    assert {:ok, revoked} =
             AshStore.transition_terminal(
               pending.id,
               :revoked,
               "operator_revoked",
               %{},
               DateTime.utc_now(),
               nil
             )

    assert revoked.state == :revoked
    assert revoked.orphan_risk_state == :none

    assert :ok =
             AshStore.record_cleanup(
               pending.id,
               %{
                 cleanup_status: :complete,
                 cancel_status: :not_required,
                 credential_status: :deleted
               },
               %{},
               nil
             )

    assert {:ok, stored} = Grant.get_by_id(pending.id, actor: @actor)
    assert stored.state == :revoked
    assert stored.orphan_risk_state == :none
    assert stored.credential_cleanup_state == :deleted
  end

  test "cleanup command results reconcile monotonically and idempotently", context do
    {:ok, pending} = AshStore.create_pending(context.grant, %{}, nil)

    {:ok, :bound, _bound} =
      AshStore.bind_credential(
        pending.id,
        31,
        fn _locked -> :ok end,
        %{},
        DateTime.utc_now(),
        nil
      )

    binding =
      context.grant.awx_scope_snapshot
      |> Map.update!(:credential_ids, &(&1 ++ [31]))
      |> Map.put(:job_id, 9_001)

    {:ok, :activated, active} =
      AshStore.activate(
        pending.id,
        binding,
        fn _locked -> :ok end,
        %{},
        DateTime.utc_now(),
        nil
      )

    assert :ok =
             AshStore.record_cleanup(
               pending.id,
               %{
                 cleanup_status: :queued,
                 cancel_status: :not_required,
                 credential_status: :delete_requested
               },
               %{},
               nil
             )

    attrs = %{
      command_id: Ash.UUID.generate(),
      cleanup_kind: "credential_delete",
      cleanup_mode: "post_activation",
      execution_id: active.execution_id,
      controller_id: active.awx_scope_snapshot["controller_id"],
      dispatch_agent_id: active.dispatch_agent_id,
      dispatch_partition_id: active.dispatch_partition_id,
      awx_job_id: active.job_binding["job_id"],
      credential_id: active.ephemeral_credential_id,
      result_status: :deleted
    }

    failed_attrs = %{attrs | command_id: Ash.UUID.generate(), result_status: :delete_failed}
    assert :ok = AshStore.reconcile_cleanup_result(pending.id, failed_attrs, nil)

    assert {:ok, failed} = Grant.get_by_id(pending.id, actor: @actor)
    assert failed.state == :active
    assert failed.credential_cleanup_state == :delete_failed
    assert failed.credential_cleanup_error_code == "callback_credential_cleanup_failed"

    assert :ok = AshStore.reconcile_cleanup_result(pending.id, attrs, nil)

    assert {:ok, deleted} = Grant.get_by_id(pending.id, actor: @actor)
    assert deleted.state == :active
    assert deleted.credential_cleanup_state == :deleted
    assert deleted.credential_cleanup_completed_at
    completed_at = deleted.credential_cleanup_completed_at

    assert :ok = AshStore.reconcile_cleanup_result(pending.id, attrs, nil)

    assert :ok =
             AshStore.reconcile_cleanup_result(
               pending.id,
               %{attrs | result_status: :delete_failed},
               nil
             )

    assert {:ok, unchanged} = Grant.get_by_id(pending.id, actor: @actor)
    assert unchanged.credential_cleanup_state == :deleted
    assert unchanged.credential_cleanup_completed_at == completed_at

    assert {:ok, events} = AuditEvent.list_for_grant(pending.id, actor: @actor)
    assert Enum.count(events, &(&1.event_type == :credential_deleted)) == 1
    assert Enum.count(events, &(&1.event_type == :credential_delete_failed)) == 1

    assert {:ok, revoked} =
             AshStore.transition_terminal(
               pending.id,
               :revoked,
               "operator_revoked",
               %{},
               DateTime.utc_now(),
               nil
             )

    assert revoked.orphan_risk_state == :cancel_requested

    cancel_attrs = %{
      attrs
      | command_id: Ash.UUID.generate(),
        cleanup_kind: "job_cancel",
        cleanup_mode: "revoked",
        result_status: :cancel_requested
    }

    assert :ok = AshStore.reconcile_cleanup_result(pending.id, cancel_attrs, nil)
    assert :ok = AshStore.reconcile_cleanup_result(pending.id, cancel_attrs, nil)

    terminal_delete_attrs = %{
      attrs
      | command_id: Ash.UUID.generate(),
        cleanup_mode: "revoked"
    }

    assert :ok = AshStore.reconcile_cleanup_result(pending.id, terminal_delete_attrs, nil)

    assert {:ok, cleaned} = Grant.get_by_id(pending.id, actor: @actor)
    assert cleaned.state == :revoked
    assert cleaned.orphan_risk_state == :cancel_requested
    assert cleaned.credential_cleanup_state == :deleted

    assert {:ok, events} = AuditEvent.list_for_grant(pending.id, actor: @actor)
    assert Enum.count(events, &(&1.event_type == :credential_deleted)) == 1
    assert Enum.count(events, &(&1.event_type == :credential_delete_failed)) == 1
    # A 2xx cancel response is only a request acknowledgement. It must not
    # synthesize a terminal cleanup-completed event before a later exact job
    # observation confirms terminal state.
    refute Enum.any?(events, &(&1.event_type == :cleanup_completed))
  end

  test "response fingerprint and size checks fail before any use row", context do
    {:ok, pending} = AshStore.create_pending(context.grant, %{}, nil)

    {:ok, :bound, _bound} =
      AshStore.bind_credential(
        pending.id,
        31,
        fn _locked -> :ok end,
        %{},
        DateTime.utc_now(),
        nil
      )

    binding =
      context.grant.awx_scope_snapshot
      |> Map.update!(:credential_ids, &(&1 ++ [31]))
      |> Map.put(:job_id, 9_001)

    {:ok, :activated, _active} =
      AshStore.activate(
        pending.id,
        binding,
        fn _locked -> :ok end,
        %{},
        DateTime.utc_now(),
        nil
      )

    response = ~s({"ok":true})
    attrs = %{consume_attrs(response) | response_digest: String.duplicate("0", 64)}

    assert {:error, :invalid_response_fingerprint} =
             AshStore.consume_once(
               pending.id,
               attrs,
               response,
               fn _locked -> :ok end,
               %{},
               DateTime.utc_now(),
               nil
             )

    oversized = :binary.copy("x", 262_145)

    assert {:error, :callback_response_too_large} =
             AshStore.consume_once(
               pending.id,
               consume_attrs(oversized),
               oversized,
               fn _locked -> :ok end,
               %{},
               DateTime.utc_now(),
               nil
             )

    assert {:ok, []} = Use.list_for_grant(pending.id, actor: @actor)
  end

  test "expiry is checked under the row lock before bind, activate, use, and replay", context do
    {:ok, pending} = AshStore.create_pending(context.grant, %{}, nil)
    expired_at_lock = context.grant.expires_at
    valid_now = context.grant.issued_at
    caller = self()

    authorize = fn _locked ->
      send(caller, :authorized)
      :ok
    end

    assert {:error, :grant_expired} =
             AshStore.bind_credential(
               pending.id,
               31,
               authorize,
               %{},
               expired_at_lock,
               nil
             )

    refute_receive :authorized
    assert {:ok, stored_pending} = Grant.get_by_id(pending.id, actor: @actor)
    assert stored_pending.awx_ephemeral_credential_id == nil

    assert {:ok, :bound, _bound} =
             AshStore.bind_credential(pending.id, 31, authorize, %{}, valid_now, nil)

    assert_receive :authorized

    binding =
      context.grant.awx_scope_snapshot
      |> Map.update!(:credential_ids, &(&1 ++ [31]))
      |> Map.put(:job_id, 9_001)

    assert {:error, :grant_expired} =
             AshStore.activate(pending.id, binding, authorize, %{}, expired_at_lock, nil)

    refute_receive :authorized
    assert {:ok, stored_bound} = Grant.get_by_id(pending.id, actor: @actor)
    assert stored_bound.state == :pending

    assert {:ok, :activated, _active} =
             AshStore.activate(pending.id, binding, authorize, %{}, valid_now, nil)

    assert_receive :authorized

    response = ~s({"ok":true})
    attrs = consume_attrs(response)

    assert {:error, :grant_expired} =
             AshStore.consume_once(
               pending.id,
               attrs,
               response,
               authorize,
               %{},
               expired_at_lock,
               nil
             )

    refute_receive :authorized
    assert {:ok, []} = Use.list_for_grant(pending.id, actor: @actor)

    assert {:ok, :committed, ^response, _consumed} =
             AshStore.consume_once(
               pending.id,
               attrs,
               response,
               authorize,
               %{},
               valid_now,
               nil
             )

    assert_receive :authorized

    assert {:error, :grant_expired} =
             AshStore.consume_once(
               pending.id,
               attrs,
               response,
               authorize,
               %{},
               expired_at_lock,
               nil
             )

    refute_receive :authorized
  end

  defp consume_attrs(response) do
    %{
      idempotency_key_verifier: <<7::256>>,
      idempotency_pepper_version: "callback-v1",
      request_digest: String.duplicate("8", 64),
      response_digest: CanonicalJSON.sha256(response),
      action: "remote_access.ssh_ca.bundle.read"
    }
  end

  defp pure_grant(ids) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    scope = %{
      controller_id: ids.controller,
      inventory_id: 34,
      job_template_id: 42,
      project_id: 3,
      scm_revision: String.duplicate("a", 40),
      content_sha256: String.duplicate("b", 64),
      execution_environment_id: 4,
      machine_credential_id: 5,
      credential_ids: [5],
      callback_credential_type_id: 6,
      callback_credential_organization_id: 2,
      callback_credential_injector_digest: String.duplicate("c", 64),
      host_limit: "farm01-pve01",
      target_count: 1,
      target_digest: String.duplicate("d", 64),
      snapshot_digest: String.duplicate("e", 64),
      targets: [
        %{
          membership_id: ids.membership,
          controller_id: ids.controller,
          inventory_id: 34,
          awx_host_id: 7,
          canonical_device_uid: "sr:device-7",
          host_name: "farm01-pve01",
          ansible_host: "192.168.2.22"
        }
      ],
      binding_id: ids.binding,
      awx_created_by_id: 11
    }

    response = %{
      manifest_sha256: String.duplicate("f", 64),
      phase: "stage",
      operation: "enroll",
      state: "present",
      targets: [
        %{
          inventory_hostname: "farm01-pve01",
          inventory_address: "192.168.2.22",
          target_identity: %{
            controller_id: ids.controller,
            inventory_id: 34,
            awx_host_id: 7,
            canonical_device_uid: "sr:device-7"
          },
          ca_keys: [
            %{
              id: "serviceradar-user-ca-2026",
              public_key:
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZm test",
              fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            }
          ],
          accounts: [
            %{name: "mfreeman", principals: ["srp_v1_AAAAAAAAAAAAAAAAAAAA"]}
          ],
          transaction: %{
            id: "txn-enroll-1",
            stage_job_id: 8_999,
            generation: "generation-1",
            machine_credential_ref: "awx-credential-ref:linux-demo"
          }
        }
      ]
    }

    approval = %{id: "approval-1", approved: true}
    policy = %{version: "ssh-policy-v3", approved: true}
    {:ok, scope_digest} = CanonicalJSON.digest(scope)
    {:ok, approval_digest} = CanonicalJSON.digest(approval)
    {:ok, policy_digest} = CanonicalJSON.digest(policy)

    %{
      id: Ash.UUIDv7.generate(),
      state: :pending,
      tenant_id: "platform",
      parent_run_id: ids.operation,
      execution_id: ids.execution,
      principal_type: :human,
      principal_id: "callback-test-user",
      principal_owner_id: nil,
      authorization_version: "role-v7",
      issuance_ceiling: %{
        permissions: [
          "ansible.runs.launch",
          "devices.remote_access.ssh.ca_bundle.read"
        ],
        actions: ["remote_access.ssh_ca.bundle.read"],
        target_keys: [String.duplicate("9", 64)],
        tenant_id: "platform",
        principal_type: :human,
        principal_id: "callback-test-user",
        max_ttl_seconds: 600,
        success_budget: 1
      },
      action: "remote_access.ssh_ca.bundle.read",
      action_version: "1.0.0",
      audience: "serviceradar.awx.callback/v1",
      issued_at: now,
      expires_at: DateTime.add(now, 300),
      budget_total: 1,
      budget_remaining: 1,
      target_keys: [String.duplicate("9", 64)],
      scope_digest: scope_digest,
      approval_digest: approval_digest,
      policy_digest: policy_digest,
      approval_snapshot: approval,
      policy_snapshot: policy,
      policy_version: "ssh-policy-v3",
      awx_scope_snapshot: scope,
      response_snapshot: response,
      binding_verified: false,
      job_binding: nil,
      ephemeral_credential_id: nil,
      dispatch_agent_id: "agent-gateway-demo",
      dispatch_partition_id: "farm01",
      launch_envelope_ref: "vault-envelope:callback-grant-1",
      verifier_digest: <<7::256>>,
      verifier_key_id: "callback-v1",
      idempotency_verifier_digest: <<7::256>>,
      idempotency_verifier_key_id: "callback-v1"
    }
  end

  defp dependency_ids do
    %{
      controller: Ash.UUID.generate(),
      operation: Ash.UUID.generate(),
      execution: Ash.UUID.generate(),
      binding: Ash.UUID.generate(),
      membership: Ash.UUID.generate(),
      dispatch: Ash.UUID.generate(),
      approval: Ash.UUID.generate()
    }
  end

  defp insert_dependencies(ids) do
    suffix = System.unique_integer([:positive])

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_controllers
        (id, name, base_url, agent_id, credential_secret_id)
      VALUES (($1::text)::uuid, $2, 'https://awx.test.invalid', 'agent-gateway-demo',
              ($3::text)::uuid)
      """,
      # ansible_controllers.credential_secret_id is a foreign key onto
      # network_credential_secrets, so a generated UUID no longer satisfies it.
      [ids.controller, "callback-store-#{suffix}", CredentialIntegrationFixtures.secret_id!()]
    )

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_automation_operations
        (id, tenant_id, action, state, mutating, check_mode,
         initiator_principal_type, initiator_principal_id, authorization_version,
         authority_ceiling, approval_snapshot, request_source, input_digest, target_digest)
      VALUES
        (($1::text)::uuid, 'platform', 'remote_access.ssh_ca.bundle.read', 'planned', true, false,
         'human', 'callback-test-user', 'role-v7', '{}'::jsonb, '{}'::jsonb,
         'interactive', $2, $3)
      """,
      [ids.operation, String.duplicate("1", 64), String.duplicate("2", 64)]
    )

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_automation_executions
        (id, operation_id, controller_id, inventory_id, job_template_id, project_id,
         scm_revision, content_sha256, execution_environment_id, machine_credential_id,
         host_limit, dispatch_id, snapshot_digest)
      VALUES (($1::text)::uuid, ($2::text)::uuid, ($3::text)::uuid, 34, 42, 3,
              $4, $5, 4, 5, 'farm01-pve01', ($6::text)::uuid, $7)
      """,
      [
        ids.execution,
        ids.operation,
        ids.controller,
        String.duplicate("a", 40),
        String.duplicate("b", 64),
        ids.dispatch,
        String.duplicate("e", 64)
      ]
    )

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.ansible_awx_template_bindings
        (id, controller_id, job_template_id, binding_version, current, approval_state,
         approval_id, approval_expires_at, inventory_policy, allowed_inventory_ids,
         project_id, scm_revision, content_sha256, project_update_on_launch,
         execution_environment_id, credentials, machine_credential_id,
         run_mode_supported, check_mode_supported, ask_inventory_on_launch,
         ask_limit_on_launch, ask_credential_on_launch, ask_job_type_on_launch,
         dispatch_markers_retained,
         inventory_groups_verified, inventory_group_names, input_schema,
         input_classifications, callback_actions, callback_credential_type_id,
         callback_credential_organization_id, callback_credential_injector_digest,
         callback_credential_slot, awx_created_by_id, reviewed_by_principal_type,
         reviewed_by_principal_id, reviewed_at, review_metadata)
      VALUES
        (($1::text)::uuid, ($2::text)::uuid, 42, 1, true, 'approved', ($3::text)::uuid,
         (now() AT TIME ZONE 'utc') + INTERVAL '1 day', 'fixed', ARRAY[34]::bigint[],
         3, $4, $5, false, 4, ARRAY['{"id":5,"kind":"ssh"}'::jsonb], 5,
         true, false, false, true, true, false, true, true, ARRAY['linux']::text[],
         '{}'::jsonb, '{}'::jsonb,
         ARRAY['remote_access.ssh_ca.bundle.read']::text[], 6, 2, $6, 'callback-env', 11,
         'human', 'callback-reviewer', (now() AT TIME ZONE 'utc'), '{}'::jsonb)
      """,
      [
        ids.binding,
        ids.controller,
        ids.approval,
        String.duplicate("a", 40),
        String.duplicate("b", 64),
        String.duplicate("c", 64)
      ]
    )
  end
end
