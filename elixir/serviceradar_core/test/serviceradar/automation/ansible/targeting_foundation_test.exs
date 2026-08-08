defmodule ServiceRadar.Automation.Ansible.TargetingFoundationTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationMutationPhase
  alias ServiceRadar.Automation.Ansible.AutomationTargetHold
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Identity.RBAC.Catalog

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260714170000_add_execution_target_source_fingerprint.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  test "AWX membership identity cannot collapse duplicate hostnames across inventories" do
    assert identity_attributes(AwxHostMembership, :source_identity) == [
             :controller_id,
             :inventory_id,
             :awx_host_id
           ]

    refute Enum.any?(Info.identities(AwxHostMembership), fn identity ->
             :host_name in identity.keys or :ansible_host in identity.keys
           end)

    assert Info.attribute(AwxHostMembership, :canonical_device_uid).allow_nil?
    assert Info.attribute(AwxHostMembership, :source_generation).constraints[:min] == 1
  end

  test "child and target identities are controller, job, and host-ID scoped" do
    assert identity_attributes(AutomationExecution, :unique_dispatch) == [:dispatch_id]

    assert identity_attributes(AutomationExecution, :unique_controller_job) == [
             :controller_id,
             :awx_job_id
           ]

    assert identity_attributes(AutomationExecutionTarget, :unique_execution_awx_host) == [
             :execution_id,
             :awx_host_id
           ]

    refute Enum.any?(Info.identities(AutomationExecutionTarget), fn identity ->
             identity.keys == [:execution_id, :host_name]
           end)
  end

  test "execution targets retain a canonical membership source fingerprint" do
    source_fingerprint = Info.attribute(AutomationExecutionTarget, :source_fingerprint)
    create = Info.action(AutomationExecutionTarget, :create)

    refute source_fingerprint.allow_nil?
    assert {Spark.Regex, :cache, [pattern, flags]} = source_fingerprint.constraints[:match]
    match = Spark.Regex.cache(pattern, flags)
    assert Regex.match?(match, "sha256:" <> String.duplicate("a", 64))
    refute Regex.match?(match, "not-a-fingerprint")
    assert :source_fingerprint in create.accept
  end

  test "source-fingerprint migration preserves historical rows but rejects unproven new targets" do
    migration = File.read!(@migration_path)

    assert migration =~ "add :source_fingerprint, :text"

    assert migration =~
             "CHECK (source_fingerprint IS NOT NULL AND source_fingerprint ~ '^sha256:[0-9a-f]{64}$') NOT VALID"
  end

  test "mutation evidence is append-only and idempotency scoped to the target" do
    assert identity_attributes(AutomationMutationPhase, :unique_idempotency_key) == [
             :execution_target_id,
             :idempotency_key
           ]

    assert identity_attributes(AutomationMutationPhase, :unique_transaction_generation) == [
             :execution_target_id,
             :transaction_id,
             :generation
           ]

    action_names =
      AutomationMutationPhase
      |> Info.actions()
      |> Enum.map(& &1.name)

    assert :record_authenticated in action_names
    refute Enum.any?(Info.actions(AutomationMutationPhase), &(&1.type == :update))
    refute Enum.any?(Info.actions(AutomationMutationPhase), &(&1.type == :destroy))
  end

  test "delegation and hold-clear permissions are administrator-only defaults" do
    admin = Catalog.permissions_for_role(:admin)
    operator = Catalog.permissions_for_role(:operator)
    viewer = Catalog.permissions_for_role(:viewer)

    for permission <- ["ansible.delegations.manage", "ansible.targets.holds.clear"] do
      assert permission in Catalog.permission_keys()
      assert MapSet.member?(admin, permission)
      refute MapSet.member?(operator, permission)
      refute MapSet.member?(viewer, permission)
    end
  end

  test "hold clearance requires approval, current policy, and reconciliation evidence" do
    clear = Info.action(AutomationTargetHold, :clear)

    assert Enum.map(clear.arguments, & &1.name) == [
             :approval_id,
             :current_policy_digest,
             :reconciliation_evidence
           ]

    assert Enum.all?(clear.arguments, &(not &1.allow_nil?))

    assert identity_attributes(AutomationTargetHold, :one_active_hold_per_device) == [
             :canonical_device_uid
           ]
  end

  test "a transport SystemActor cannot stamp itself as the hold-clearance principal" do
    hold = %AutomationTargetHold{active: true}

    changeset =
      Ash.Changeset.for_update(
        hold,
        :clear,
        %{
          approval_id: Ash.UUID.generate(),
          current_policy_digest: "sha256:policy",
          reconciliation_evidence: %{
            "recovery_method" => "fresh_ssh",
            "evidence_digest" => "sha256:verification",
            "verified_at" => "2026-07-12T20:00:00Z",
            "verification_ids" => ["verification:1"]
          }
        },
        actor: SystemActor.system(:ansible_hold_clearance)
      )

    refute changeset.valid?

    assert Enum.any?(changeset.errors, fn error ->
             Exception.message(error) =~ "transport system actor"
           end)
  end

  test "hold clearance rejects arbitrary secret-capable evidence maps" do
    hold = %AutomationTargetHold{active: true}

    changeset =
      Ash.Changeset.for_update(
        hold,
        :clear,
        %{
          approval_id: Ash.UUID.generate(),
          current_policy_digest: "sha256:policy",
          reconciliation_evidence: %{"password" => "must-not-be-audited"}
        },
        actor: %{id: "user:admin", role: :admin}
      )

    refute changeset.valid?

    assert Enum.any?(changeset.errors, fn error ->
             Exception.message(error) =~ "must contain only recovery_method"
           end)
  end

  test "hold clearance stamps the authorized principal and canonical evidence" do
    approval_id = Ash.UUID.generate()
    hold = %AutomationTargetHold{active: true}

    changeset =
      Ash.Changeset.for_update(
        hold,
        :clear,
        %{
          approval_id: approval_id,
          current_policy_digest: "sha256:current-policy",
          reconciliation_evidence: %{
            recovery_method: "rollback_verified",
            evidence_digest: "sha256:recovery-evidence",
            verified_at: "2026-07-12T20:00:00Z",
            verification_ids: ["verification:rollback", "verification:reconnect"]
          }
        },
        actor: %{id: "user:hold-admin", role: :admin}
      )

    assert changeset.valid?
    assert Ash.Changeset.get_attribute(changeset, :active) == false
    assert Ash.Changeset.get_attribute(changeset, :cleared_by_principal_type) == :human
    assert Ash.Changeset.get_attribute(changeset, :cleared_by_principal_id) == "user:hold-admin"
    assert Ash.Changeset.get_attribute(changeset, :clearance_approval_id) == approval_id

    assert Ash.Changeset.get_attribute(changeset, :clearance_evidence) == %{
             "recovery_method" => "rollback_verified",
             "evidence_digest" => "sha256:recovery-evidence",
             "verified_at" => "2026-07-12T20:00:00Z",
             "verification_ids" => ["verification:rollback", "verification:reconnect"]
           }
  end

  defp identity_attributes(resource, name) do
    resource
    |> Info.identities()
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:keys)
  end
end
