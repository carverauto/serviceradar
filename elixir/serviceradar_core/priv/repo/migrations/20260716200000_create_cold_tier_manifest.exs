defmodule ServiceRadar.Repo.Migrations.CreateColdTierManifest do
  @moduledoc """
  Cold-tier export manifest + per-table tier boundaries
  (OpenSpec add-tiered-telemetry-offload, tasks 2.1/2.3).

  The manifest is the commit protocol for chunk exports: objects on the
  deployment bucket are invisible to every consumer until their manifest row
  is `verified`. Boundaries carry the cold completeness frontier (F) and the
  analytics-head-acknowledged query boundary (B), with the invariant
  drop point <= B <= F enforced by the exporter's write-then-ack ordering.
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE platform.cold_chunk_exports (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      table_name text NOT NULL,
      chunk_name text NOT NULL,
      range_start timestamptz NOT NULL,
      range_end timestamptz NOT NULL,
      object_keys text[] NOT NULL DEFAULT '{}',
      row_count bigint,
      bytes bigint,
      content_checksum text,
      status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'exported', 'verified', 'quarantined', 'pruned')),
      attempts integer NOT NULL DEFAULT 0,
      last_error text,
      exported_at timestamptz,
      verified_at timestamptz,
      pruned_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT cold_chunk_exports_table_chunk_unique UNIQUE (table_name, chunk_name),
      CONSTRAINT cold_chunk_exports_range_valid CHECK (range_end > range_start)
    )
    """

    execute """
    CREATE INDEX cold_chunk_exports_table_status_idx
      ON platform.cold_chunk_exports (table_name, status)
    """

    execute """
    CREATE INDEX cold_chunk_exports_table_range_end_idx
      ON platform.cold_chunk_exports (table_name, range_end)
    """

    execute """
    CREATE TABLE platform.cold_tier_boundaries (
      table_name text PRIMARY KEY,
      frontier timestamptz,
      query_boundary timestamptz,
      boundary_acked_at timestamptz,
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT cold_tier_boundaries_order CHECK (
        query_boundary IS NULL OR frontier IS NULL OR query_boundary <= frontier
      )
    )
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS platform.cold_tier_boundaries"
    execute "DROP TABLE IF EXISTS platform.cold_chunk_exports"
  end
end
