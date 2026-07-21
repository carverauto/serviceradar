defmodule ServiceRadar.Repo.Migrations.AddExecutionTargetSourceFingerprint do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"
  @constraint :ansible_automation_execution_targets_source_fingerprint

  def up do
    alter table(:ansible_automation_execution_targets, prefix: @prefix) do
      # Historical targets did not retain the source fingerprint that was
      # reconciled at launch time. They remain readable, but cannot satisfy a
      # current-authority check that now requires immutable provenance.
      add :source_fingerprint, :text
    end

    # New rows must carry the canonical source value. `NOT VALID` deliberately
    # avoids treating a current membership as historical proof for existing
    # immutable target rows, while the non-null clause prevents raw writes
    # from bypassing the resource-level requirement.
    execute("""
    ALTER TABLE platform.ansible_automation_execution_targets
      ADD CONSTRAINT #{@constraint}
      CHECK (source_fingerprint IS NOT NULL AND source_fingerprint ~ '^sha256:[0-9a-f]{64}$') NOT VALID
    """)
  end

  def down do
    drop constraint(:ansible_automation_execution_targets, @constraint, prefix: @prefix)

    alter table(:ansible_automation_execution_targets, prefix: @prefix) do
      remove :source_fingerprint
    end
  end
end
