defmodule ServiceRadar.Repo.Migrations.AddMergeAuditLookupIndexes do
  @moduledoc """
  Indexes for the two ways `merge_audit` is actually queried.

  The table has carried only its primary key on `event_id` since it was created
  in `20260117090000_rebuild_schema.exs`, so every lookup sequentially scans it:
  `Resolver.latest_merge_target/2` filtering `from_device_id` and sorting by
  `created_at`, and the per-pair merge cooldown probe checking both directions.

  This lands ahead of the identity-fence work because both the finding-lineage
  path and the stranded-row repair walk merge chains through this table. Shipping
  a chain-walking repair job onto an unindexed table is how a repair becomes an
  outage.

  Separate migration from the column add because concurrent index builds cannot
  run inside a transaction.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:merge_audit, [:from_device_id, :created_at],
        prefix: "platform",
        name: "merge_audit_from_device_created_idx",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:merge_audit, [:to_device_id],
        prefix: "platform",
        name: "merge_audit_to_device_idx",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:merge_audit, [:from_device_id, :created_at],
        prefix: "platform",
        name: "merge_audit_from_device_created_idx",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:merge_audit, [:to_device_id],
        prefix: "platform",
        name: "merge_audit_to_device_idx",
        concurrently: true
      )
    )
  end
end
