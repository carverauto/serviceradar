defmodule ServiceRadar.Automation.Ansible.PreflightSnapshotPersistenceTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationOperation

  @resources [AutomationOperation, AutomationExecution]
  @attestation_fields [
    :preflight_evidence_id,
    :immutable_launch_snapshot,
    :immutable_launch_snapshot_digest
  ]
  @mutable_actions %{
    AutomationOperation => [:record_state, :request_cancel],
    AutomationExecution => [:record_state, :bind_job, :record_scope_verified]
  }
  @migration_path "priv/repo/migrations/20260714160200_add_automation_preflight_snapshot_evidence.exs"

  test "preflight evidence and immutable snapshots are create-only durable fields" do
    for resource <- @resources do
      create = Info.action(resource, :create)

      assert MapSet.subset?(MapSet.new(@attestation_fields), MapSet.new(create.accept))

      for action_name <- Map.fetch!(@mutable_actions, resource) do
        action = Info.action(resource, action_name)

        refute Enum.any?(@attestation_fields, &(&1 in action.accept))
      end

      attributes = resource |> Info.attributes() |> Map.new(&{&1.name, &1})

      assert attributes.preflight_evidence_id.allow_nil?
      assert attributes.immutable_launch_snapshot.allow_nil? == false
      assert attributes.immutable_launch_snapshot.default == %{}
      assert attributes.immutable_launch_snapshot_digest.allow_nil?

      refute attributes.preflight_evidence_id.public?
      refute attributes.immutable_launch_snapshot.public?
      refute attributes.immutable_launch_snapshot_digest.public?
    end
  end

  test "both resources mirror the database pair constraint" do
    expected_constraints = %{
      AutomationOperation => "ansible_automation_operations_preflight_snapshot_pair",
      AutomationExecution => "ansible_automation_executions_preflight_snapshot_pair"
    }

    for {resource, constraint_name} <- expected_constraints do
      assert Enum.any?(PostgresInfo.check_constraints(resource), fn constraint ->
               # AshPostgres requires the attribute key to be a real field; the
               # SQL still enforces the multi-column empty-or-complete pair.
               constraint.name == constraint_name and
                 constraint.attribute == :preflight_evidence_id
             end)
    end
  end

  test "migration makes attested tuples durable while preserving legacy empty rows" do
    migration = File.read!(@migration_path)

    assert migration =~ "references(:automation_awx_launch_preflight_evidences"
    assert migration =~ "on_delete: :restrict"
    assert migration =~ "immutable_launch_snapshot, :map, null: false, default: %{}"
    assert migration =~ "immutable_launch_snapshot_digest IS NOT NULL"
    assert migration =~ "immutable_launch_snapshot_digest ~ '^[0-9a-f]{64}$'"
    assert migration =~ "immutable_launch_snapshot = '{}'::jsonb"
    assert migration =~ "immutable_launch_snapshot <> '{}'::jsonb"
    assert migration =~ "ansible_automation_operations_preflight_evidence_idx"
    assert migration =~ "ansible_automation_executions_preflight_evidence_idx"
  end
end
