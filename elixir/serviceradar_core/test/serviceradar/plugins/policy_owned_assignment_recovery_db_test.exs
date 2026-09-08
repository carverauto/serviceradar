defmodule ServiceRadar.Plugins.PolicyOwnedAssignmentRecoveryDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequest
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryWorker
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Lease
  alias ServiceRadar.Repo

  @moduletag :integration

  defmodule AuditWriterStub do
    @moduledoc false

    def write_async(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:policy_recovery_audit, opts})
      :ok
    end
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    RBAC.clear_process_cache()

    :erlang.trace(self(), true, [:call])
    :erlang.trace_pattern({PluginPolicyAssignmentRecoveryWorker, :enqueue, 1}, true, [:local])

    on_exit(fn ->
      RBAC.clear_process_cache()
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({PluginPolicyAssignmentRecoveryWorker, :enqueue, 1}, false, [:local])
    end)

    :ok
  end

  test "active request reuse reauthorizes the current caller before it can enqueue work" do
    fixture = active_request_fixture!()

    # This stale caller shape is sufficient for the read policy, but its
    # persisted profile deliberately has no plugin permission. Reuse must not
    # trust the caller's supplied permission set or return the active request.
    stale_actor = %{
      id: fixture.user_id,
      email: "stale-caller@example.test",
      role: :admin,
      permissions: MapSet.new(["settings.plugins.manage"])
    }

    assert {:error, :current_permission_denied} =
             PolicyOwnedAssignmentRecovery.request(fixture.legacy_assignment_id,
               actor: stale_actor,
               confirm: true,
               audit_writer: {AuditWriterStub, test_pid: self()}
             )

    assert_receive {:policy_recovery_audit, audit_opts}

    assert Keyword.fetch!(audit_opts, :details) == %{
             recovery_kind: "policy_owned",
             outcome: "denied",
             reason: "current_permission_denied"
           }

    refute_receive {
      :trace,
      _pid,
      :call,
      {PluginPolicyAssignmentRecoveryWorker, :enqueue, [_request_id]}
    }
  end

  test "expired or stolen leases are fenced before policy recovery materialization" do
    stolen = executing_lease_fixture!(worker_lease_token: Ash.UUID.generate())

    expired =
      executing_lease_fixture!(lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))

    # These unique agent IDs are the identities a materializer would write
    # assignments/credential-broker grants for. A rejected fence must leave
    # both families empty and must not cross the post-commit dispatch boundary.
    Enum.each([stolen, expired], fn fixture ->
      assert {:error, :recovery_lease_lost} =
               Repo.transaction(fn ->
                 case Lease.fence_current(
                        fixture.request_id,
                        fixture.worker_lease_token,
                        DateTime.utc_now()
                      ) do
                   :ok ->
                     Repo.rollback(:unexpected_live_lease)

                   {:error, :recovery_lease_lost} = error ->
                     Repo.rollback(elem(error, 1))

                   {:error, reason} ->
                     Repo.rollback(reason)
                 end
               end)

      assert 0 == count_rows("plugin_assignments", "agent_uid", fixture.agent_uid)

      assert 0 ==
               count_rows(
                 "credential_broker_grants",
                 "agent_id",
                 fixture.agent_uid
               )
    end)

    # Executor dispatches only after both materialization and durable terminal
    # persistence. A failed transaction returns here without a config side
    # effect; the executor-level regression above covers that concrete branch.
    refute_received :policy_recovery_config_push
  end

  test "lease claim is a conditional database update" do
    live = executing_lease_fixture!([])

    expired =
      executing_lease_fixture!(lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))

    actor = SystemActor.system(:plugin_policy_assignment_recovery_executor)
    now = DateTime.utc_now()
    replacement_token = Ash.UUID.generate()
    replacement_expiry = DateTime.add(now, 30 * 60, :second)

    assert {:error, :recovery_lease_lost} =
             Lease.claim_current(
               live.request_id,
               replacement_token,
               now,
               replacement_expiry,
               actor: actor
             )

    assert :ok =
             Lease.claim_current(
               expired.request_id,
               replacement_token,
               now,
               replacement_expiry,
               actor: actor
             )

    assert {:ok, reclaimed} =
             PluginPolicyAssignmentRecoveryRequest.get_by_id(expired.request_id, actor: actor)

    assert reclaimed.status == :executing
    assert reclaimed.lease_token == replacement_token
    assert reclaimed.lease_expires_at == replacement_expiry
  end

  test "an expired lease cannot atomically finish a recovery request" do
    fixture =
      executing_lease_fixture!(lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))

    actor = SystemActor.system(:plugin_policy_assignment_recovery_executor)

    assert {:ok, request} =
             PluginPolicyAssignmentRecoveryRequest.get_by_id(fixture.request_id, actor: actor)

    assert {:error, :recovery_lease_lost} =
             Lease.finish_current(
               request.id,
               fixture.worker_lease_token,
               :failed,
               [],
               DateTime.utc_now(),
               actor: actor
             )

    assert {:ok, unchanged} =
             PluginPolicyAssignmentRecoveryRequest.get_by_id(fixture.request_id, actor: actor)

    assert unchanged.status == :executing
    assert unchanged.lease_token == fixture.worker_lease_token
    assert unchanged.completed_at == nil
  end

  defp active_request_fixture! do
    now = DateTime.utc_now()
    unique = System.unique_integer([:positive])

    ids = %{
      user_id: Ash.UUID.generate(),
      profile_id: Ash.UUID.generate(),
      request_id: Ash.UUIDv7.generate(),
      legacy_assignment_id: Ash.UUID.generate(),
      owner_id: Ash.UUID.generate(),
      package_id: Ash.UUID.generate(),
      plugin_id: "policy-recovery-active-request-#{unique}"
    }

    {1, _} =
      Repo.insert_all(
        "role_profiles",
        [
          %{
            id: Ecto.UUID.dump!(ids.profile_id),
            system_name: nil,
            name: "Policy recovery denied #{unique}",
            description: "Current-authority recovery test profile",
            permissions: [],
            system: false,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform"
      )

    {1, _} =
      Repo.insert_all(
        "ng_users",
        [
          %{
            id: Ecto.UUID.dump!(ids.user_id),
            email: "policy-recovery-denied-#{unique}@example.test",
            display_name: "Policy Recovery Denied",
            role: "admin",
            status: "active",
            role_profile_id: Ecto.UUID.dump!(ids.profile_id),
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform"
      )

    {1, _} =
      Repo.insert_all(
        "plugins",
        [
          %{
            plugin_id: ids.plugin_id,
            name: "Policy recovery fixture #{unique}",
            description: nil,
            source_repo_url: nil,
            homepage_url: nil,
            disabled: false,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform"
      )

    {1, _} =
      Repo.insert_all(
        "plugin_packages",
        [
          %{
            id: Ecto.UUID.dump!(ids.package_id),
            plugin_id: ids.plugin_id,
            name: "Policy recovery fixture #{unique}",
            version: "1.0.0",
            description: nil,
            entrypoint: "run_check",
            runtime: "wasi-preview1",
            outputs: "serviceradar.plugin_result.v1",
            manifest: %{},
            config_schema: %{},
            signature: %{},
            source_type: "upload",
            status: "approved",
            approved_capabilities: [],
            approved_permissions: %{},
            approved_resources: %{},
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform"
      )

    {1, _} =
      Repo.insert_all(
        "plugin_assignments",
        [
          %{
            id: Ecto.UUID.dump!(ids.legacy_assignment_id),
            agent_uid: "policy-recovery-active-request-agent-#{unique}",
            plugin_package_id: Ecto.UUID.dump!(ids.package_id),
            plugin_id: ids.plugin_id,
            partition_id: nil,
            source: "policy",
            source_key: "policy-recovery-active-request-source-#{unique}",
            policy_id: ids.owner_id,
            enabled: false,
            interval_seconds: 60,
            timeout_seconds: 10,
            params: %{},
            permissions_override: %{},
            resources_override: %{},
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform"
      )

    {1, _} =
      Repo.insert_all(
        "plugin_policy_assignment_recovery_requests",
        [
          %{
            id: Ecto.UUID.dump!(ids.request_id),
            legacy_assignment_id: Ecto.UUID.dump!(ids.legacy_assignment_id),
            legacy_agent_uid: "recovery-agent-#{unique}",
            legacy_policy_id: ids.owner_id,
            legacy_plugin_package_id: Ecto.UUID.dump!(ids.package_id),
            owner_kind: "plugin_target_policy",
            owner_id: Ecto.UUID.dump!(ids.owner_id),
            owner_purpose: nil,
            requested_by_principal_type: "human",
            requested_by_principal_id: Ecto.UUID.dump!(ids.user_id),
            requested_by_principal_owner_id: nil,
            status: "requested",
            outcome_details: %{},
            replacement_assignment_ids: [],
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform"
      )

    %{
      user_id: ids.user_id,
      legacy_assignment_id: ids.legacy_assignment_id
    }
  end

  defp executing_lease_fixture!(overrides) do
    now = DateTime.utc_now()
    unique = System.unique_integer([:positive])
    request_id = Ash.UUIDv7.generate()
    legacy_assignment_id = Ash.UUID.generate()
    owner_id = Ash.UUID.generate()
    package_id = Ash.UUID.generate()
    principal_id = Ash.UUID.generate()
    stored_lease_token = Ash.UUID.generate()
    worker_lease_token = Keyword.get(overrides, :worker_lease_token, stored_lease_token)

    lease_expires_at =
      Keyword.get(overrides, :lease_expires_at, DateTime.add(now, 5 * 60, :second))

    {1, _} =
      Repo.insert_all(
        "plugin_policy_assignment_recovery_requests",
        [
          %{
            id: Ecto.UUID.dump!(request_id),
            legacy_assignment_id: Ecto.UUID.dump!(legacy_assignment_id),
            legacy_agent_uid: "lease-fence-agent-#{unique}",
            legacy_policy_id: owner_id,
            legacy_plugin_package_id: Ecto.UUID.dump!(package_id),
            owner_kind: "plugin_target_policy",
            owner_id: Ecto.UUID.dump!(owner_id),
            owner_purpose: nil,
            requested_by_principal_type: "human",
            requested_by_principal_id: Ecto.UUID.dump!(principal_id),
            requested_by_principal_owner_id: nil,
            status: "executing",
            outcome_details: %{},
            replacement_assignment_ids: [],
            started_at: now,
            lease_token: Ecto.UUID.dump!(stored_lease_token),
            lease_expires_at: lease_expires_at,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform"
      )

    %{
      request_id: request_id,
      worker_lease_token: worker_lease_token,
      agent_uid: "lease-fence-agent-#{unique}"
    }
  end

  defp count_rows(table, column, value)
       when table in ["plugin_assignments", "credential_broker_grants"] and
              column in ["agent_uid", "agent_id"] do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.#{table} WHERE #{column} = $1",
        [value]
      )

    count
  end
end
