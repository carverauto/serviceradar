defmodule ServiceRadar.Repo.Migrations.AddAnalyticsManifestCompaction do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:analytics_file_manifest, prefix: "platform") do
      add :retired_at, :utc_datetime_usec
      add :replacement_key, :text
      add :objects_deleted_at, :utc_datetime_usec
    end

    execute """
    ALTER TABLE platform.analytics_file_manifest
      DROP CONSTRAINT analytics_file_manifest_status_check,
      ADD CONSTRAINT analytics_file_manifest_status_check
        CHECK (status IN ('pending', 'verified', 'published', 'superseded', 'expired')),
      ADD CONSTRAINT analytics_file_manifest_retirement_check
        CHECK (
          (status = 'superseded' AND retired_at IS NOT NULL AND replacement_key IS NOT NULL) OR
          (status = 'expired' AND retired_at IS NOT NULL AND replacement_key IS NULL) OR
          (status NOT IN ('superseded', 'expired') AND retired_at IS NULL AND replacement_key IS NULL AND objects_deleted_at IS NULL)
        )
    """

    create index(:analytics_file_manifest, [:table_name, :retired_at, :id],
             prefix: "platform",
             where: "status IN ('superseded', 'expired') AND objects_deleted_at IS NULL",
             name: :analytics_file_manifest_retired_idx
           )
  end

  # Re-publishing superseded sources would double count compacted data. A
  # rollback must stop if compaction has run; it cannot safely undo object IO.
  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM platform.analytics_file_manifest WHERE status IN ('superseded', 'expired')) THEN
        RAISE EXCEPTION 'Cannot roll back manifest retirement after publication or expiry';
      END IF;
    END $$
    """

    drop index(:analytics_file_manifest, [:table_name, :retired_at, :id],
           prefix: "platform",
           name: :analytics_file_manifest_retired_idx
         )

    execute """
    ALTER TABLE platform.analytics_file_manifest
      DROP CONSTRAINT analytics_file_manifest_retirement_check,
      DROP CONSTRAINT analytics_file_manifest_status_check,
      ADD CONSTRAINT analytics_file_manifest_status_check
        CHECK (status IN ('pending', 'verified', 'published'))
    """

    alter table(:analytics_file_manifest, prefix: "platform") do
      remove :objects_deleted_at
      remove :replacement_key
      remove :retired_at
    end
  end
end
