defmodule ServiceRadar.Repo.Migrations.AddAwxReviewedLaunchSnapshots do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    alter table(:ansible_awx_template_bindings, prefix: @prefix) do
      # Nullable on purpose: historical digest-only records must remain visible
      # and revocable, but the Ash create action rejects newly approved rows
      # without the complete contract.
      add :reviewed_launch_snapshot, :map
      add :reviewed_launch_snapshot_digest, :text
    end

    create constraint(
             :ansible_awx_template_bindings,
             :ansible_awx_template_bindings_reviewed_launch_snapshot_pair,
             check: """
             (
               reviewed_launch_snapshot IS NULL
               AND reviewed_launch_snapshot_digest IS NULL
             )
             OR
             (
               reviewed_launch_snapshot IS NOT NULL
               AND reviewed_launch_snapshot_digest ~ '^[0-9a-f]{64}$'
               AND review_metadata->>'awx_snapshot_digest' = reviewed_launch_snapshot_digest
             )
             """,
             prefix: @prefix
           )
  end
end
