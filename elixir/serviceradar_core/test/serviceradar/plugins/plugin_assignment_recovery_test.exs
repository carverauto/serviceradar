defmodule ServiceRadar.Plugins.PluginAssignmentRecoveryTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Forbidden
  alias Ash.Resource.Info, as: ResourceInfo
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginAssignmentRecovery
  alias ServiceRadar.Plugins.PluginAssignmentRecoveryAudit
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  @secret_schema %{
    "type" => "object",
    "additionalProperties" => true,
    "properties" => %{
      "endpoint" => %{"type" => "string"},
      "password_secret_ref" => %{"type" => "string", "secretRef" => true}
    }
  }

  defmodule AuditWriterCapture do
    @moduledoc false
    def write_async(opts) do
      send(self(), {:plugin_assignment_recovery_audit, opts})
      :ok
    end
  end

  defmodule DummyControlSession do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, name: opts[:name])
    end

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call({:push_config, _response}, _from, state), do: {:reply, :ok, state}

    def handle_call({:send_command, command, _context}, _from, state) do
      {:reply, {:ok, command}, state}
    end

    def handle_call(_request, _from, state), do: {:reply, :ok, state}
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    original_secret = Application.get_env(:serviceradar_core, :crypto_secret)
    Application.put_env(:serviceradar_core, :crypto_secret, String.duplicate("r", 32))

    on_exit(fn ->
      if original_secret do
        Application.put_env(:serviceradar_core, :crypto_secret, original_secret)
      else
        Application.delete_env(:serviceradar_core, :crypto_secret)
      end
    end)

    %{
      actor: %{
        id: Ash.UUID.generate(),
        email: "plugin-recovery@serviceradar.local",
        role: :admin
      },
      unique_id: :erlang.unique_integer([:positive])
    }
  end

  test "manual recovery clones a fresh bound assignment, preserves linked encrypted material, and is idempotent",
       %{actor: actor, unique_id: unique_id} do
    plugin_id = "legacy-recovery-#{unique_id}"
    agent_uid = "legacy-recovery-agent-#{unique_id}"
    partition_id = "farm01"
    test_pid = self()

    config_dispatcher = fn dispatch_partition_id, dispatch_agent_uid ->
      send(test_pid, {:recovery_config_push, dispatch_partition_id, dispatch_agent_uid})
      :ok
    end

    register_control_session!(agent_uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    end)

    {:ok, package} = create_approved_package(actor, plugin_id, @secret_schema)

    stored_params =
      SecretRefs.prepare_params_for_storage(@secret_schema, %{
        "endpoint" => "https://pve.example.test",
        "password_secret_ref" => "not-returned-to-recovery-caller"
      })

    assert {:ok, created} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package.id,
                 source: :manual,
                 enabled: true,
                 interval_seconds: 120,
                 timeout_seconds: 20,
                 params: stored_params
               },
               actor: actor
             )
             |> Ash.Changeset.set_context(%{config_schema: @secret_schema})
             |> Ash.create(actor: actor)

    # Simulate exactly the migration's legacy quarantine. NULL remains valid
    # because the row is disabled, and it must not collide with the replacement.
    Repo.query!(
      "UPDATE platform.plugin_assignments SET enabled = false, partition_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(created.id)]
    )

    scope = current_user_scope!(unique_id, ["settings.plugins.manage"])

    assert {:ok,
            %{agent_uid: ^agent_uid, state: :available, partition_id: ^partition_id} =
              partition_preview} =
             PluginAssignmentRecovery.authenticated_partition_preview(agent_uid, scope: scope)

    assert partition_preview |> Map.keys() |> Enum.sort() == [:agent_uid, :partition_id, :state]

    assert {:ok, preview} = PluginAssignmentRecovery.preview(created.id, scope: scope)
    assert preview.recovery_kind == :manual_reapproval
    assert preview.status == :available
    assert preview.authenticated_partition_id == partition_id
    refute Map.has_key?(preview, :params)

    assert {:ok, result} =
             PluginAssignmentRecovery.recover_manual(created.id,
               scope: scope,
               confirm: true,
               config_dispatcher: config_dispatcher,
               config_dispatch_async?: false
             )

    assert result.outcome == :recovered
    assert result.legacy_assignment_id == created.id
    assert result.authenticated_partition_id == partition_id
    refute Map.has_key?(result, :params)

    assert_receive {:recovery_config_push, ^partition_id, ^agent_uid}
    refute_receive {:recovery_config_push, _, _}

    assert {:ok, legacy} = assignment_by_id(created.id, actor)
    assert legacy.enabled == false
    assert is_nil(legacy.partition_id)

    assert {:ok, replacement} = assignment_by_id(result.replacement_assignment_id, actor)
    assert replacement.id != created.id
    assert replacement.source == :manual
    assert replacement.enabled
    assert replacement.partition_id == partition_id
    assert replacement.interval_seconds == 120
    assert replacement.timeout_seconds == 20

    ref = replacement.params["password_secret_ref"]
    assert String.starts_with?(ref, "secretref:")
    assert is_binary(replacement.params["_secret_material"][ref])
    refute replacement.params["_secret_material"][ref] == "not-returned-to-recovery-caller"
    refute Map.has_key?(SecretRefs.public_params(replacement.params), "_secret_material")

    assert {:ok, [audit]} = audits_for_legacy(created.id, actor)
    assert audit.outcome == :recovered
    assert audit.reason == :reapproved
    assert audit.legacy_assignment_id == created.id
    assert audit.replacement_assignment_id == replacement.id
    assert audit.authenticated_agent_id == agent_uid
    assert audit.authenticated_partition_id == partition_id
    refute Map.has_key?(Map.from_struct(audit), :params)

    assert {:ok, legacy_detail} =
             PluginAssignmentRecovery.legacy_detail(created.id, scope: scope)

    assert legacy_detail.manual_recovery == %{state: :reapproved}
    assert legacy_detail.policy_recovery == nil
    refute inspect(legacy_detail) =~ "secretref:"

    assert {:ok, retry} =
             PluginAssignmentRecovery.recover_manual(created.id,
               actor: actor,
               confirm: true,
               config_dispatcher: config_dispatcher,
               config_dispatch_async?: false
             )

    assert retry.idempotent?
    assert retry.replacement_assignment_id == replacement.id
    assert_receive {:recovery_config_push, ^partition_id, ^agent_uid}
    refute_receive {:recovery_config_push, _, _}
    assert {:ok, [only_audit]} = audits_for_legacy(created.id, actor)
    assert only_audit.id == audit.id
  end

  test "plugin managers cannot forge or enumerate recovery audits while trusted recovery remains idempotent",
       %{
         actor: actor,
         unique_id: unique_id
       } do
    candidate = quarantined_manual_assignment!(actor, unique_id)

    plugin_manager = %{
      id: Ash.UUID.generate(),
      role: :viewer,
      permissions: MapSet.new(["settings.plugins.manage"])
    }

    forged_audit_attrs = %{
      legacy_assignment_id: candidate.assignment.id,
      actor_id: plugin_manager.id,
      actor_type: :user,
      agent_uid: candidate.agent_uid,
      authenticated_agent_id: candidate.agent_uid,
      authenticated_partition_id: candidate.partition_id,
      outcome: :recovered,
      reason: :already_recovered
    }

    # The former generic create action was the forged-idempotency path. The
    # remaining action is explicitly system-only even for a plugin manager.
    refute ResourceInfo.action(PluginAssignmentRecoveryAudit, :create)
    assert ResourceInfo.action(PluginAssignmentRecoveryAudit, :record_recovery)

    assert {:error, %Forbidden{}} =
             PluginAssignmentRecoveryAudit
             |> Ash.Changeset.for_create(:record_recovery, forged_audit_attrs,
               actor: plugin_manager
             )
             |> Ash.create(actor: plugin_manager, authorize?: true)

    wrong_system_actor = SystemActor.system(:different_internal_component)

    assert {:error, %Forbidden{}} =
             PluginAssignmentRecoveryAudit
             |> Ash.Changeset.for_create(:record_recovery, forged_audit_attrs,
               actor: wrong_system_actor
             )
             |> Ash.create(actor: wrong_system_actor, authorize?: true)

    assert {:error, %Forbidden{}} =
             PluginAssignmentRecoveryAudit
             |> Ash.Query.for_read(
               :for_legacy_assignment,
               %{legacy_assignment_id: candidate.assignment.id},
               actor: plugin_manager
             )
             |> Ash.read(actor: plugin_manager)

    assert {:ok, []} = audits_for_legacy(candidate.assignment.id, plugin_manager)

    assert {:ok, recovered} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               actor: plugin_manager,
               confirm: true
             )

    assert recovered.outcome == :recovered

    assert {:ok, [audit]} = audits_for_legacy(candidate.assignment.id, plugin_manager)
    assert audit.actor_id == plugin_manager.id
    assert audit.replacement_assignment_id == recovered.replacement_assignment_id

    assert {:ok, retry} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               actor: plugin_manager,
               confirm: true
             )

    assert retry.idempotent?
    assert retry.replacement_assignment_id == recovered.replacement_assignment_id
    assert {:ok, [only_audit]} = audits_for_legacy(candidate.assignment.id, plugin_manager)
    assert only_audit.id == audit.id
  end

  test "automatic recovery restores verified first-party manual history without confirmation", %{
    actor: actor,
    unique_id: unique_id
  } do
    candidate =
      quarantined_manual_assignment!(actor, unique_id,
        source_type: :first_party,
        verification_status: "verified",
        signature: %{"key_id" => "release-test-key"},
        wasm_object_key: "plugins/automatic/#{unique_id}.wasm"
      )

    assert {:ok, summary} =
             PluginAssignmentRecovery.recover_automatic(
               config_dispatcher: fn _partition_id, _agent_uid -> :ok end,
               config_dispatch_async?: false
             )

    assert summary.scanned == 1
    assert summary.manual_candidates == 1
    assert summary.recovered == 1
    assert summary.failed == 0

    assert {:ok, [audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert audit.outcome == :recovered
    assert audit.actor_type == :service
    assert audit.actor_id == "system:plugin_assignment_automatic_recovery"

    assert {:ok, replacement} = assignment_by_id(audit.replacement_assignment_id, actor)
    assert replacement.enabled
    assert replacement.partition_id == candidate.partition_id
    assert replacement.agent_uid == candidate.agent_uid
  end

  test "automatic recovery records uploaded manual history as terminal quarantined audit history",
       %{
         actor: actor,
         unique_id: unique_id
       } do
    candidate = quarantined_manual_assignment!(actor, unique_id)

    assert {:ok, summary} = PluginAssignmentRecovery.recover_automatic()
    assert summary.manual_candidates == 1
    assert summary.recovered == 0
    assert summary.deferred == 1
    assert summary.failed == 0

    assert {:ok, [audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert audit.outcome == :package_unavailable
    assert audit.reason == :plugin_package_not_trusted

    assert {:ok, retry_summary} = PluginAssignmentRecovery.recover_automatic()
    assert retry_summary.recovered == 0
    assert retry_summary.deferred == 1
    assert retry_summary.failed == 0

    assert {:ok, [only_audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert only_audit.id == audit.id

    assert {:ok, legacy} = assignment_by_id(candidate.assignment.id, actor)
    refute legacy.enabled
    assert is_nil(legacy.partition_id)
  end

  test "automatic recovery records a revoked package once instead of retrying it every sweep", %{
    actor: actor,
    unique_id: unique_id
  } do
    candidate =
      quarantined_manual_assignment!(actor, unique_id,
        source_type: :first_party,
        verification_status: "verified",
        signature: %{"key_id" => "release-test-key"},
        wasm_object_key: "plugins/revoked/#{unique_id}.wasm"
      )

    assert {:ok, _revoked_package} =
             candidate.package
             |> Ash.Changeset.for_update(
               :revoke,
               %{denied_reason: "automatic recovery terminal-audit test"},
               actor: actor
             )
             |> Ash.update(actor: actor)

    assert {:ok, summary} = PluginAssignmentRecovery.recover_automatic()
    assert summary.recovered == 0
    assert summary.deferred == 1
    assert summary.failed == 0

    assert {:ok, [audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert audit.outcome == :package_unavailable
    assert audit.reason == :plugin_package_not_approved

    assert {:ok, retry_summary} = PluginAssignmentRecovery.recover_automatic()
    assert retry_summary.recovered == 0
    assert retry_summary.deferred == 1
    assert retry_summary.failed == 0

    assert {:ok, [only_audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert only_audit.id == audit.id
  end

  test "legacy detail is an actor-authorized, secret-free projection", %{
    actor: actor,
    unique_id: unique_id
  } do
    raw_secret = "never-expose-#{unique_id}"

    stored_params =
      SecretRefs.prepare_params_for_storage(@secret_schema, %{
        "endpoint" => "https://pve.example.test",
        "password_secret_ref" => raw_secret
      })

    candidate =
      quarantined_manual_assignment!(actor, unique_id,
        config_schema: @secret_schema,
        params: stored_params
      )

    scope = current_user_scope!(unique_id, ["settings.plugins.manage"])

    assert {:ok, detail} =
             PluginAssignmentRecovery.legacy_detail(candidate.assignment.id, scope: scope)

    assert detail.legacy_assignment_id == candidate.assignment.id
    assert detail.agent_uid == candidate.agent_uid
    assert detail.source == :manual
    assert detail.recovery_kind == :manual_reapproval

    assert detail.owner == %{
             kind: :manual,
             label: "Manual assignment",
             reference: nil,
             state: :available
           }

    assert detail.config_compatibility == %{
             state: :compatible,
             reason: :current_schema_valid
           }

    assert detail.authenticated_partition == %{
             state: :available,
             partition_id: candidate.partition_id
           }

    assert detail.policy_recovery == nil
    assert detail.manual_recovery == nil

    refute Map.has_key?(detail, :params)
    refute Map.has_key?(detail, :policy_id)
    refute inspect(detail) =~ raw_secret
    refute inspect(detail) =~ "secretref:"
    refute inspect(detail) =~ "_secret_material"

    denied_actor = %{id: Ash.UUID.generate(), role: :viewer, permissions: MapSet.new()}

    assert {:error, :initiating_actor_required} =
             PluginAssignmentRecovery.legacy_detail(candidate.assignment.id)

    assert {:error, :authorization_denied} =
             PluginAssignmentRecovery.legacy_detail(candidate.assignment.id, actor: denied_actor)
  end

  test "legacy recovery candidates are read in bounded pages", %{
    actor: actor,
    unique_id: unique_id
  } do
    first_candidate = quarantined_manual_assignment!(actor, unique_id)

    second_candidate =
      quarantined_manual_assignment!(actor, :erlang.unique_integer([:positive]))

    assert {:ok, [first]} =
             PluginAssignmentRecovery.list_legacy(actor: actor, limit: 1)

    assert {:ok, [second]} =
             PluginAssignmentRecovery.list_legacy(
               actor: actor,
               limit: 1,
               after_id: first.legacy_assignment_id
             )

    legacy_ids = [first_candidate.assignment.id, second_candidate.assignment.id]

    assert first.legacy_assignment_id in legacy_ids
    assert second.legacy_assignment_id in legacy_ids
    refute first.legacy_assignment_id == second.legacy_assignment_id

    assert {:error, :invalid_legacy_list_cursor} =
             PluginAssignmentRecovery.list_legacy(actor: actor, after_id: "not-a-legacy-cursor")
  end

  test "scope authorization reloads persisted permissions instead of trusting the scope", %{
    actor: actor,
    unique_id: unique_id
  } do
    candidate = quarantined_manual_assignment!(actor, unique_id)

    # This represents a long-lived LiveView scope whose cached permissions no
    # longer match the persisted role profile. Passing a broad direct actor at
    # the same time must not bypass the supplied scope either.
    stale_scope = %{
      current_user_scope!(unique_id, [])
      | permissions: MapSet.new(["settings.plugins.manage"])
    }

    assert {:error, :authorization_denied} =
             PluginAssignmentRecovery.legacy_detail(candidate.assignment.id,
               scope: stale_scope,
               actor: actor
             )
  end

  test "legacy unbound rows reject generic update and destroy paths for users and system actors",
       %{
         actor: actor,
         unique_id: unique_id
       } do
    candidate = quarantined_manual_assignment!(actor, unique_id)
    {:ok, legacy} = assignment_by_id(candidate.assignment.id, actor)

    for mutation_actor <- [actor, SystemActor.system(:legacy_assignment_mutation_test)] do
      assert {:error, update_error} =
               legacy
               |> Ash.Changeset.for_update(:update, %{interval_seconds: 61})
               |> Ash.update(actor: mutation_actor)

      assert inspect(update_error) =~
               "legacy unbound assignments require explicit recovery and cannot be mutated"

      assert {:error, destroy_error} =
               legacy
               |> Ash.Changeset.for_destroy(:destroy, %{}, actor: mutation_actor)
               |> Ash.destroy(actor: mutation_actor)

      assert inspect(destroy_error) =~
               "legacy unbound assignments require explicit recovery and cannot be mutated"
    end

    assert {:ok, persisted_legacy} = assignment_by_id(legacy.id, actor)
    assert persisted_legacy.enabled == false
    assert is_nil(persisted_legacy.partition_id)
    assert persisted_legacy.interval_seconds == legacy.interval_seconds

    bound_agent_uid = "bound-assignment-mutation-agent-#{unique_id}"
    register_control_session!(bound_agent_uid, candidate.partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister(
        {:agent_control, candidate.partition_id, bound_agent_uid, node()}
      )
    end)

    assert {:ok, bound} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: bound_agent_uid,
                 plugin_package_id: candidate.package.id,
                 source: :manual,
                 enabled: false,
                 params: %{}
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    assert bound.enabled == false
    assert bound.partition_id == candidate.partition_id

    assert {:ok, %{interval_seconds: 61}} =
             bound
             |> Ash.Changeset.for_update(:update, %{interval_seconds: 61})
             |> Ash.update(actor: actor)
  end

  test "manual recovery rejects policy-owned legacy rows without cloning", %{
    actor: actor,
    unique_id: unique_id
  } do
    plugin_id = "policy-legacy-recovery-#{unique_id}"
    agent_uid = "policy-legacy-agent-#{unique_id}"
    partition_id = "tonka01"

    register_control_session!(agent_uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    end)

    {:ok, package} = create_approved_package(actor, plugin_id, %{})

    policy_name = "Legacy recovery policy #{unique_id}"

    assert {:ok, policy} =
             PluginTargetPolicy
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: policy_name,
                 plugin_package_id: package.id
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    assert {:ok, created} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package.id,
                 source: :policy,
                 source_key: "legacy-policy-#{unique_id}",
                 policy_id: policy.id,
                 enabled: true,
                 params: %{}
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    Repo.query!(
      "UPDATE platform.plugin_assignments SET enabled = false, partition_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(created.id)]
    )

    assert {:ok, detail} = PluginAssignmentRecovery.legacy_detail(created.id, actor: actor)

    assert detail.owner == %{
             kind: :plugin_target_policy,
             label: policy_name,
             reference: policy.id,
             state: :available
           }

    assert detail.config_compatibility == %{state: :compatible, reason: :current_schema_valid}

    recovery_request_id = Ash.UUIDv7.generate()
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(
        "plugin_policy_assignment_recovery_requests",
        [
          %{
            id: Ecto.UUID.dump!(recovery_request_id),
            legacy_assignment_id: Ecto.UUID.dump!(created.id),
            legacy_agent_uid: agent_uid,
            legacy_policy_id: policy.id,
            legacy_plugin_package_id: Ecto.UUID.dump!(package.id),
            owner_kind: "plugin_target_policy",
            owner_id: Ecto.UUID.dump!(policy.id),
            owner_purpose: nil,
            requested_by_principal_type: "human",
            requested_by_principal_id: Ecto.UUID.dump!(actor.id),
            requested_by_principal_owner_id: nil,
            status: "conflict",
            outcome_code: "conflict",
            outcome_details: %{"outcome" => "conflict"},
            replacement_assignment_ids: [],
            completed_at: now,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform"
      )

    assert {:ok, refreshed_detail} =
             PluginAssignmentRecovery.legacy_detail(created.id, actor: actor)

    assert refreshed_detail.policy_recovery == %{state: :conflict, replacement_count: 0}
    refute Map.has_key?(detail, :params)

    assert {:error, :policy_assignment_requires_reconciliation} =
             PluginAssignmentRecovery.recover_manual(created.id, actor: actor, confirm: true)

    assert {:ok, legacy} = assignment_by_id(created.id, actor)
    assert legacy.enabled == false
    assert is_nil(legacy.partition_id)
    assert {:ok, [audit]} = audits_for_legacy(created.id, actor)
    assert audit.outcome == :rejected
    assert audit.reason == :policy_assignment_requires_reconciliation
  end

  test "confirmed policy recovery requests are created with the action argument before Ash validates",
       %{
         actor: actor,
         unique_id: unique_id
       } do
    plugin_id = "policy-request-recovery-#{unique_id}"
    agent_uid = "policy-request-recovery-agent-#{unique_id}"
    partition_id = "farm01"

    register_control_session!(agent_uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    end)

    {:ok, package} = create_approved_package(actor, plugin_id, %{})

    assert {:ok, policy} =
             PluginTargetPolicy
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Policy request recovery #{unique_id}",
                 plugin_package_id: package.id
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    assert {:ok, legacy_assignment} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package.id,
                 source: :policy,
                 source_key: "policy-request-recovery-#{unique_id}",
                 policy_id: policy.id,
                 enabled: true,
                 params: %{}
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    Repo.query!(
      "UPDATE platform.plugin_assignments SET enabled = false, partition_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(legacy_assignment.id)]
    )

    scope = current_user_scope!(unique_id, ["settings.plugins.manage"])

    assert {:ok, request} =
             PolicyOwnedAssignmentRecovery.request(legacy_assignment.id,
               scope: scope,
               confirm: true,
               audit_writer: AuditWriterCapture
             )

    assert request.legacy_assignment_id == legacy_assignment.id
    assert request.legacy_agent_uid == agent_uid
    assert request.legacy_policy_id == policy.id
    assert request.legacy_plugin_package_id == package.id
    assert request.owner_kind == :plugin_target_policy
    assert request.owner_id == policy.id
    assert request.status == :requested

    assert_receive {:plugin_assignment_recovery_audit, audit_event}

    assert audit_event[:details] == %{
             recovery_kind: "policy_owned",
             outcome: "accepted",
             reason: "request_accepted"
           }
  end

  test "unsupported historical policy owners are non-actionable without suppressing current owner forms",
       %{actor: actor, unique_id: unique_id} do
    plugin_id = "unsupported-policy-owner-#{unique_id}"
    agent_uid = "unsupported-policy-owner-agent-#{unique_id}"
    partition_id = "farm01"
    unsupported_owner = "ansible:awx-inventory-sync"

    register_control_session!(agent_uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    end)

    {:ok, package} = create_approved_package(actor, plugin_id, %{})

    assert {:ok, created} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package.id,
                 source: :policy,
                 source_key: "unsupported-policy-owner-#{unique_id}",
                 policy_id: unsupported_owner,
                 enabled: true,
                 params: %{}
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    Repo.query!(
      "UPDATE platform.plugin_assignments SET enabled = false, partition_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(created.id)]
    )

    assert PluginAssignmentRecovery.classify(%{
             source: :policy,
             enabled: false,
             partition_id: nil,
             policy_id: unsupported_owner
           }) == :unsupported_policy_owner

    assert PluginAssignmentRecovery.classify(%{
             "policy_id" => unsupported_owner,
             source: :policy,
             enabled: false,
             partition_id: nil
           }) == :unsupported_policy_owner

    assert PluginAssignmentRecovery.classify(%{
             source: :policy,
             enabled: false,
             partition_id: nil,
             policy_id: Ash.UUID.generate()
           }) == :policy_reconciliation

    assert PluginAssignmentRecovery.classify(%{
             source: :policy,
             enabled: false,
             partition_id: nil,
             policy_id: "network-credential-rule:#{Ash.UUID.generate()}:console_access"
           }) == :policy_reconciliation

    assert {:ok, detail} = PluginAssignmentRecovery.legacy_detail(created.id, actor: actor)

    assert detail.recovery_kind == :unsupported_policy_owner
    assert detail.recovery_reason == :unsupported_policy_owner
    assert detail.policy_recovery == nil

    assert detail.owner == %{
             kind: :unknown,
             label: "Unsupported historical policy owner",
             reference: nil,
             state: :unavailable
           }

    assert {:ok, summaries} = PluginAssignmentRecovery.list_legacy(actor: actor, limit: 100)
    summary = Enum.find(summaries, &(&1.legacy_assignment_id == created.id))

    assert summary.recovery_kind == :unsupported_policy_owner
    assert summary.recovery_reason == :unsupported_policy_owner
    refute Map.has_key?(summary, :policy_id)

    assert {:error, :unsupported_policy_owner} =
             PolicyOwnedAssignmentRecovery.request(created.id,
               actor: actor,
               confirm: true,
               audit_writer: AuditWriterCapture
             )

    assert_receive {:plugin_assignment_recovery_audit, audit_event}

    assert audit_event[:details] == %{
             recovery_kind: "policy_owned",
             outcome: "denied",
             reason: "unsupported_policy_owner"
           }

    refute inspect(audit_event) =~ unsupported_owner
  end

  test "offline control evidence fails closed and records an unavailable outcome", %{
    actor: actor,
    unique_id: unique_id
  } do
    candidate = quarantined_manual_assignment!(actor, unique_id)
    unregister_control_session!(candidate.agent_uid, candidate.partition_id)
    test_pid = self()

    config_dispatcher = fn dispatch_partition_id, dispatch_agent_uid ->
      send(
        test_pid,
        {:unexpected_recovery_config_push, dispatch_partition_id, dispatch_agent_uid}
      )

      :ok
    end

    assert {:ok, preview} =
             PluginAssignmentRecovery.authenticated_partition_preview(candidate.agent_uid,
               actor: actor
             )

    assert preview == %{
             agent_uid: candidate.agent_uid,
             state: :unavailable,
             reason: :authenticated_agent_partition_unavailable
           }

    assert {:error, :authenticated_agent_partition_unavailable} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               actor: actor,
               confirm: true,
               audit_writer: AuditWriterCapture,
               config_dispatcher: config_dispatcher,
               config_dispatch_async?: false
             )

    refute_receive {:unexpected_recovery_config_push, _, _}

    assert_receive {:plugin_assignment_recovery_audit, audit_event}
    assert audit_event[:action] == :plugin_assignment_manual_recovery
    assert audit_event[:resource_type] == "plugin_assignment_recovery"
    assert audit_event[:resource_id] == candidate.assignment.id
    assert audit_event[:actor] == %{id: actor.id}

    assert audit_event[:details] == %{
             legacy_assignment_id: candidate.assignment.id,
             actor_id: actor.id,
             outcome: :evidence_unavailable,
             reason: :authenticated_agent_partition_unavailable
           }

    refute Map.has_key?(audit_event[:details], :agent_uid)
    refute Map.has_key?(audit_event[:details], :params)
    refute Map.has_key?(audit_event[:details], :authenticated_partition_id)

    assert {:ok, [audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert audit.outcome == :evidence_unavailable
    assert audit.reason == :authenticated_agent_partition_unavailable
    assert is_nil(audit.replacement_assignment_id)
  end

  test "mismatched control metadata is discarded fail-closed instead of becoming recovery evidence",
       %{
         actor: actor,
         unique_id: unique_id
       } do
    candidate = quarantined_manual_assignment!(actor, unique_id)
    agent_uid = candidate.agent_uid
    partition_id = candidate.partition_id
    unregister_control_session!(agent_uid, partition_id)

    assert {:ok, _pid} =
             ProcessRegistry.register(
               {:agent_control, partition_id, agent_uid, node()},
               %{
                 # The registry key is not evidence. AgentCommandBus must reject
                 # this metadata because it does not match the requested UID.
                 agent_id: "different-agent-#{unique_id}",
                 partition_id: partition_id,
                 gateway_node: node(),
                 capabilities: ["wasm"]
               }
             )

    assert {:ok,
            %{
              agent_uid: ^agent_uid,
              state: :unavailable,
              reason: :authenticated_agent_partition_unavailable
            }} =
             PluginAssignmentRecovery.authenticated_partition_preview(candidate.agent_uid,
               actor: actor
             )

    assert {:error, :authenticated_agent_partition_unavailable} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               actor: actor,
               confirm: true
             )

    assert {:ok, [audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert audit.outcome == :evidence_unavailable
    assert audit.authenticated_agent_id == nil
    assert audit.authenticated_partition_id == nil
  end

  test "recovery requires an explicit authorized initiating actor", %{
    actor: actor,
    unique_id: unique_id
  } do
    candidate = quarantined_manual_assignment!(actor, unique_id)

    assert {:error, :initiating_actor_required} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               confirm: true,
               audit_writer: AuditWriterCapture
             )

    assert_receive {:plugin_assignment_recovery_audit, missing_actor_event}
    assert missing_actor_event[:actor] == nil

    assert missing_actor_event[:details] == %{
             legacy_assignment_id: candidate.assignment.id,
             outcome: :denied,
             reason: :initiating_actor_required
           }

    denied_actor = %{
      id: Ash.UUID.generate(),
      role: :viewer,
      permissions: MapSet.new()
    }

    assert {:error, :authorization_denied} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               actor: denied_actor,
               confirm: true,
               audit_writer: AuditWriterCapture
             )

    assert_receive {:plugin_assignment_recovery_audit, denied_event}
    assert denied_event[:actor] == %{id: denied_actor.id}

    assert denied_event[:details] == %{
             legacy_assignment_id: candidate.assignment.id,
             actor_id: denied_actor.id,
             outcome: :denied,
             reason: :authorization_denied
           }

    assert {:error, :confirmation_required} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               actor: actor,
               audit_writer: AuditWriterCapture
             )

    assert_receive {:plugin_assignment_recovery_audit, confirmation_event}
    assert confirmation_event[:actor] == %{id: actor.id}

    assert confirmation_event[:details] == %{
             legacy_assignment_id: candidate.assignment.id,
             actor_id: actor.id,
             outcome: :denied,
             reason: :confirmation_required
           }

    assert {:ok, []} = audits_for_legacy(candidate.assignment.id, actor)
    assert {:ok, legacy} = assignment_by_id(candidate.assignment.id, actor)
    assert legacy.enabled == false
    assert is_nil(legacy.partition_id)
  end

  test "recovery rejects a package that is no longer approved", %{
    actor: actor,
    unique_id: unique_id
  } do
    candidate = quarantined_manual_assignment!(actor, unique_id)

    assert {:ok, _revoked} =
             candidate.package
             |> Ash.Changeset.for_update(
               :revoke,
               %{denied_reason: "recovery package approval test"},
               actor: actor
             )
             |> Ash.update(actor: actor)

    assert {:error, :plugin_package_not_approved} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               actor: actor,
               confirm: true
             )

    assert {:ok, [audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert audit.outcome == :package_unavailable
    assert audit.reason == :plugin_package_not_approved
  end

  test "recovery rejects legacy params that no longer meet the current package schema", %{
    actor: actor,
    unique_id: unique_id
  } do
    candidate = quarantined_manual_assignment!(actor, unique_id, config_schema: %{})

    current_schema = %{
      "type" => "object",
      "additionalProperties" => true,
      "required" => ["now_required"],
      "properties" => %{
        "now_required" => %{"type" => "string"}
      }
    }

    assert {:ok, _updated_package} =
             candidate.package
             |> Ash.Changeset.for_update(:update, %{config_schema: current_schema}, actor: actor)
             |> Ash.update(actor: actor)

    assert {:error, :params_not_recoverable} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               actor: actor,
               confirm: true
             )

    assert {:ok, [audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert audit.outcome == :schema_invalid
    assert audit.reason == :params_not_recoverable
  end

  test "recovery never overwrites an active bound assignment for the same plugin", %{
    actor: actor,
    unique_id: unique_id
  } do
    candidate = quarantined_manual_assignment!(actor, unique_id)

    assert {:ok, active} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: candidate.agent_uid,
                 plugin_package_id: candidate.package.id,
                 source: :manual,
                 enabled: true,
                 params: %{}
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    assert active.partition_id == candidate.partition_id

    assert {:error, :active_assignment_conflict} =
             PluginAssignmentRecovery.recover_manual(candidate.assignment.id,
               actor: actor,
               confirm: true
             )

    assert {:ok, [audit]} = audits_for_legacy(candidate.assignment.id, actor)
    assert audit.outcome == :conflict
    assert audit.reason == :active_assignment_conflict
    assert {:ok, legacy} = assignment_by_id(candidate.assignment.id, actor)
    assert legacy.enabled == false
    assert is_nil(legacy.partition_id)
  end

  defp assignment_by_id(id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor)
  end

  defp audits_for_legacy(legacy_assignment_id, _actor) do
    audit_lookup_actor = SystemActor.system(:plugin_assignment_recovery_audit_lookup)

    PluginAssignmentRecoveryAudit
    |> Ash.Query.for_read(
      :for_legacy_assignment,
      %{legacy_assignment_id: legacy_assignment_id},
      actor: audit_lookup_actor
    )
    |> Ash.read(actor: audit_lookup_actor)
  end

  defp quarantined_manual_assignment!(actor, unique_id, opts \\ []) do
    agent_uid = Keyword.get(opts, :agent_uid, "manual-recovery-agent-#{unique_id}")
    partition_id = Keyword.get(opts, :partition_id, "farm01")
    plugin_id = Keyword.get(opts, :plugin_id, "manual-recovery-plugin-#{unique_id}")
    config_schema = Keyword.get(opts, :config_schema, %{})
    params = Keyword.get(opts, :params, %{})

    register_control_session!(agent_uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    end)

    {:ok, package} = create_approved_package(actor, plugin_id, config_schema, opts)

    assert {:ok, assignment} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package.id,
                 source: :manual,
                 enabled: true,
                 params: params
               },
               actor: actor
             )
             |> Ash.Changeset.set_context(%{config_schema: config_schema})
             |> Ash.create(actor: actor)

    Repo.query!(
      "UPDATE platform.plugin_assignments SET enabled = false, partition_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(assignment.id)]
    )

    %{assignment: assignment, package: package, agent_uid: agent_uid, partition_id: partition_id}
  end

  defp register_control_session!(agent_uid, partition_id) do
    metadata = %{
      agent_id: agent_uid,
      partition_id: partition_id,
      gateway_node: node(),
      capabilities: ["wasm"]
    }

    name =
      ProcessRegistry.via({:agent_control, partition_id, agent_uid, node()}, metadata)

    {:ok, pid} = DummyControlSession.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    end)

    assert_control_partition(agent_uid, partition_id, 40)
  end

  defp unregister_control_session!(agent_uid, partition_id) do
    :ok = ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    assert_control_session_absent(agent_uid, 40)
  end

  defp assert_control_partition(_agent_uid, _partition_id, 0),
    do: flunk("control-session partition did not converge")

  defp assert_control_partition(agent_uid, partition_id, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(partition_id, agent_uid, nil) do
      {:ok, %{agent_id: ^agent_uid, partition_id: ^partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        assert_control_partition(agent_uid, partition_id, attempts - 1)
    end
  end

  defp assert_control_session_absent(_agent_uid, 0),
    do: flunk("control-session did not disappear")

  defp assert_control_session_absent(agent_uid, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(agent_uid) do
      {:error, _reason} ->
        :ok

      _other ->
        Process.sleep(10)
        assert_control_session_absent(agent_uid, attempts - 1)
    end
  end

  defp create_approved_package(actor, plugin_id, config_schema, opts \\ []) do
    {:ok, _plugin} =
      Plugin
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Plugin Assignment Recovery"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    manifest = %{
      "id" => plugin_id,
      "name" => "Plugin Assignment Recovery",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "capabilities" => ["submit_result"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 100,
        "max_open_connections" => 1
      }
    }

    assert {:ok, package} =
             PluginPackage
             |> Ash.Changeset.for_create(
               :create,
               %{
                 plugin_id: plugin_id,
                 name: "Plugin Assignment Recovery",
                 version: "1.0.0",
                 entrypoint: "run_check",
                 runtime: "wasi-preview1",
                 outputs: "serviceradar.plugin_result.v1",
                 manifest: manifest,
                 config_schema: config_schema,
                 display_contract: %{},
                 content_hash: "sha256:#{plugin_id}",
                 signature: Keyword.get(opts, :signature, %{}),
                 source_type: Keyword.get(opts, :source_type, :upload),
                 verification_status: Keyword.get(opts, :verification_status)
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    package =
      case Keyword.get(opts, :wasm_object_key) do
        object_key when is_binary(object_key) ->
          assert {:ok, updated} =
                   package
                   |> Ash.Changeset.for_update(:update, %{wasm_object_key: object_key},
                     actor: actor
                   )
                   |> Ash.update(actor: actor)

          updated

        _ ->
          package
      end

    package
    |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp current_user_scope!(unique_id, permissions) when is_list(permissions) do
    actor = SystemActor.system(:plugin_assignment_recovery_test)
    suffix = "#{unique_id}-#{System.unique_integer([:positive])}"

    assert {:ok, profile} =
             RoleProfile
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Plugin recovery scope #{suffix}",
                 description: "Test-only current-authority profile",
                 permissions: permissions
               },
               actor: actor,
               context: %{privilege_boundary_owned: true}
             )
             |> Ash.create(actor: actor)

    assert {:ok, user} =
             User
             |> Ash.Changeset.new()
             |> Ash.Changeset.set_argument(:password, "scope-password-#{suffix}-valid")
             |> Ash.Changeset.for_create(
               :create,
               %{
                 email: "plugin-recovery-scope-#{suffix}@serviceradar.local",
                 display_name: "Plugin recovery scope #{suffix}",
                 role: :viewer,
                 role_profile_id: profile.id
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    # This value is deliberately not the source of authorization. The recovery
    # boundary must reload the user's current profile before it acts.
    %{user: user, permissions: MapSet.new(["stale.scope.permission"])}
  end
end
