defmodule ServiceRadar.Repo.Migrations.AddPrefixTagDatasets do
  @moduledoc """
  Adds snapshot-versioned IP/CIDR prefix-tag storage and flow enrichment columns.

  Tables follow the netflow_provider_dataset_snapshots pattern, with a per-source
  single-active partial unique index so manual and NetBox snapshots coexist.
  Flow columns are additive on the ocsf_network_activity hypertable.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS platform.prefix_tag_snapshots (
      id UUID PRIMARY KEY,
      source TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'building',
      source_url TEXT,
      source_etag TEXT,
      source_sha256 TEXT,
      fetched_at TIMESTAMPTZ,
      promoted_at TIMESTAMPTZ,
      is_active BOOLEAN NOT NULL DEFAULT FALSE,
      record_count INTEGER NOT NULL DEFAULT 0,
      metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      CONSTRAINT prefix_tag_snapshots_status_check
        CHECK (status IN ('building', 'active', 'superseded', 'failed'))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS prefix_tag_snapshots_single_active_per_source_idx
      ON platform.prefix_tag_snapshots (source)
      WHERE is_active
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS prefix_tag_snapshots_source_status_idx
      ON platform.prefix_tag_snapshots (source, status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS platform.prefix_tags (
      id UUID PRIMARY KEY,
      snapshot_id UUID NOT NULL
        REFERENCES platform.prefix_tag_snapshots(id) ON DELETE CASCADE,
      prefix CIDR NOT NULL,
      vrf TEXT,
      tags JSONB NOT NULL DEFAULT '[]'::jsonb,
      site TEXT,
      role TEXT,
      tenant TEXT,
      status TEXT,
      partition TEXT,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS prefix_tags_snapshot_idx
      ON platform.prefix_tags (snapshot_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS prefix_tags_prefix_gist_idx
      ON platform.prefix_tags USING gist (prefix inet_ops)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS prefix_tags_snapshot_prefix_vrf_uidx
      ON platform.prefix_tags (snapshot_id, prefix, COALESCE(vrf, ''))
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS prefix_tags_tags_gin_idx
      ON platform.prefix_tags USING gin (tags)
    """)

    # JSONB (not Ecto :map) so tag chains can be JSON arrays.
    execute("""
    ALTER TABLE platform.ocsf_network_activity
      ADD COLUMN IF NOT EXISTS src_prefix_tags JSONB,
      ADD COLUMN IF NOT EXISTS dst_prefix_tags JSONB,
      ADD COLUMN IF NOT EXISTS src_prefix_tags_source TEXT,
      ADD COLUMN IF NOT EXISTS dst_prefix_tags_source TEXT
    """)

    # jsonb GIN indexes for SRQL tag filters (@> containment).
    # Created non-concurrently; empty columns on a new feature path keep lock
    # time acceptable. Revisit CONCURRENTLY if enabling against large prod tables.
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_src_prefix_tags
      ON platform.ocsf_network_activity USING gin (src_prefix_tags)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_dst_prefix_tags
      ON platform.ocsf_network_activity USING gin (dst_prefix_tags)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_dst_prefix_tags")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_src_prefix_tags")

    execute("""
    ALTER TABLE platform.ocsf_network_activity
      DROP COLUMN IF EXISTS dst_prefix_tags_source,
      DROP COLUMN IF EXISTS src_prefix_tags_source,
      DROP COLUMN IF EXISTS dst_prefix_tags,
      DROP COLUMN IF EXISTS src_prefix_tags
    """)


    execute("DROP INDEX IF EXISTS platform.prefix_tags_tags_gin_idx")
    execute("DROP INDEX IF EXISTS platform.prefix_tags_snapshot_prefix_vrf_uidx")
    execute("DROP INDEX IF EXISTS platform.prefix_tags_prefix_gist_idx")
    execute("DROP INDEX IF EXISTS platform.prefix_tags_snapshot_idx")
    execute("DROP TABLE IF EXISTS platform.prefix_tags")

    execute("DROP INDEX IF EXISTS platform.prefix_tag_snapshots_source_status_idx")
    execute("DROP INDEX IF EXISTS platform.prefix_tag_snapshots_single_active_per_source_idx")
    execute("DROP TABLE IF EXISTS platform.prefix_tag_snapshots")
  end
end
