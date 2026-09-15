defmodule ServiceRadar.Repo.Migrations.CreateAnalyticsFileManifest do
  @moduledoc """
  Manifest of verified analytics Parquet objects on the primary.

  The analytics head is disposable; published keys live here so a truncated
  COPY cannot be treated as query-visible (OpenSpec add-analytics-store-drivers).
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE platform.analytics_file_manifest (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      table_name text NOT NULL,
      object_key text NOT NULL,
      staging_key text NOT NULL,
      partition_date date NOT NULL,
      row_count bigint,
      content_checksum text,
      batch_id text NOT NULL,
      status text NOT NULL DEFAULT 'published'
        CHECK (status IN ('pending', 'verified', 'published')),
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT analytics_file_manifest_object_key_unique UNIQUE (object_key)
    )
    """

    execute """
    CREATE INDEX analytics_file_manifest_table_date_idx
      ON platform.analytics_file_manifest (table_name, partition_date)
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS platform.analytics_file_manifest"
  end
end
