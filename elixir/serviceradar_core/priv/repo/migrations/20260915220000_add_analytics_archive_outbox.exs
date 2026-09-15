defmodule ServiceRadar.Repo.Migrations.AddAnalyticsArchiveOutbox do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE platform.analytics_archive_batches (
      id uuid PRIMARY KEY,
      table_name text NOT NULL,
      partition_date date NOT NULL,
      min_timestamp timestamptz NOT NULL,
      max_timestamp timestamptz NOT NULL,
      payload bytea,
      payload_bytes bigint NOT NULL CHECK (payload_bytes >= 0),
      content_checksum text NOT NULL,
      schema_version integer NOT NULL,
      row_count integer NOT NULL CHECK (row_count > 0),
      state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'published')),
      published_object_key text,
      last_reconciled_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CHECK (
        (state = 'pending' AND payload IS NOT NULL AND payload_bytes = octet_length(payload)) OR
        (state = 'published' AND payload IS NULL AND payload_bytes = 0 AND published_object_key IS NOT NULL)
      )
    )
    """

    execute """
    CREATE INDEX analytics_archive_batches_reconcile_idx
      ON platform.analytics_archive_batches (last_reconciled_at ASC NULLS FIRST, inserted_at, id)
      WHERE state = 'pending'
    """

    execute """
    CREATE TABLE platform.analytics_delivery_receipts (
      id text PRIMARY KEY,
      claim_group uuid NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """

    alter table(:analytics_file_manifest, prefix: "platform") do
      add :archive_batch_id,
          references(:analytics_archive_batches,
            type: :uuid,
            prefix: "platform",
            on_delete: :restrict
          )
    end

    create unique_index(:analytics_file_manifest, [:archive_batch_id],
             prefix: "platform",
             name: :analytics_file_manifest_archive_batch_id_unique
           )
  end

  def down do
    alter table(:analytics_file_manifest, prefix: "platform") do
      remove :archive_batch_id
    end

    drop table(:analytics_delivery_receipts, prefix: "platform")
    drop table(:analytics_archive_batches, prefix: "platform")
  end
end
