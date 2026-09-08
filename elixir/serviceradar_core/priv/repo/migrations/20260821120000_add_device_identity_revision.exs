defmodule ServiceRadar.Repo.Migrations.AddDeviceIdentityRevision do
  @moduledoc """
  Monotonic identity revision on devices, plus the finding-lineage table.

  `merge_audit` records that a merge happened, but nothing monotonic was attached
  to the device itself, so in-flight work had no value to pin and later check to
  discover that its identity decision had gone stale. The device row had nothing
  usable either: no lock_version, no update timestamp, no counter. `modified_time`
  cannot substitute -- it is `timestamp(0)`, wall clock, and is not written by
  every mutation.

  `identity_revision` is bumped on every identity transition: merge (both the
  source and the survivor), unmerge, split, alias invalidation, identifier
  reassignment, soft delete and restore. It is deliberately NOT bumped by
  high-frequency non-identity writes such as `:touch`, `:gateway_sync` or
  `:set_availability`, which is why this is a dedicated column rather than an Ash
  `optimistic_lock` on the resource.

  NOT NULL with a default matters beyond tidiness: with a nullable column,
  `NULL + 1 = NULL`, and a NULL revision silently matches nothing -- a fence that
  fails open. `ADD COLUMN ... NOT NULL DEFAULT` is catalog-only on PostgreSQL 11+,
  so this does not rewrite the table.

  See openspec/changes/add-device-identity-fence.
  """

  use Ecto.Migration

  def up do
    alter table(:ocsf_devices, prefix: "platform") do
      add_if_not_exists(:identity_revision, :bigint, null: false, default: 1)
    end

    # Lineage for anomaly findings whose identity is re-keyed by a merge.
    #
    # Core recomputes `finding_uid` from the canonical device, so a merge changes
    # it. Correcting the episode row in place would orphan findings already
    # written under the previous hash, so the pair is recorded here.
    #
    # Rows are written by INGEST at the moment a re-key is observed, never by the
    # merge on a prediction about edge behaviour: the edge identifies from a local
    # hostname, a polled target IP, or its agent id, and never re-identifies after
    # a merge.
    create_if_not_exists table(:anomaly_finding_lineage, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:previous_finding_uid, :text, null: false)
      add(:new_finding_uid, :text, null: false)
      add(:episode_uid, :text, null: false)
      add(:previous_device_uid, :text)
      add(:new_device_uid, :text)

      add(:observed_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    # Deliberately NOT unique on previous_finding_uid alone: a device merged twice
    # produces two hops, and that constraint would reject the second.
    create_if_not_exists(
      unique_index(:anomaly_finding_lineage, [:previous_finding_uid, :new_finding_uid],
        prefix: "platform",
        name: "anomaly_finding_lineage_pair_uidx"
      )
    )

    create_if_not_exists(
      index(:anomaly_finding_lineage, [:episode_uid],
        prefix: "platform",
        name: "anomaly_finding_lineage_episode_idx"
      )
    )
  end

  def down do
    drop_if_exists(index(:anomaly_finding_lineage, [:episode_uid], prefix: "platform"))

    drop_if_exists(
      unique_index(:anomaly_finding_lineage, [:previous_finding_uid, :new_finding_uid],
        prefix: "platform"
      )
    )

    drop_if_exists(table(:anomaly_finding_lineage, prefix: "platform"))

    alter table(:ocsf_devices, prefix: "platform") do
      remove_if_exists(:identity_revision, :bigint)
    end
  end
end
