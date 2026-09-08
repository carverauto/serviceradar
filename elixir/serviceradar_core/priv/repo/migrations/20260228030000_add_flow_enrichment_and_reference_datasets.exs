defmodule ServiceRadar.Repo.Migrations.AddFlowEnrichmentAndReferenceDatasets do
  @moduledoc """
  Adds persisted flow enrichment columns and CNPG-backed reference datasets.

  This migration introduces:
  - additive enrichment columns on `platform.ocsf_network_activity`
  - cloud provider CIDR snapshot + prefix tables
  - IEEE OUI snapshot + prefix tables
  """

  use Ecto.Migration

  def up do
    alter table(:ocsf_network_activity, prefix: "platform") do
      add :protocol_source, :text
      add :tcp_flags_labels, {:array, :text}
      add :tcp_flags_source, :text
      add :dst_service_label, :text
      add :dst_service_source, :text
      add :direction_label, :text
      add :direction_source, :text
      add :src_hosting_provider, :text
      add :src_hosting_provider_source, :text
      add :dst_hosting_provider, :text
      add :dst_hosting_provider_source, :text
      add :src_mac, :text
      add :dst_mac, :text
      add :src_mac_vendor, :text
      add :src_mac_vendor_source, :text
      add :dst_mac_vendor, :text
      add :dst_mac_vendor_source, :text
    end

    create index(:ocsf_network_activity, [:direction_label, :time],
             prefix: "platform",
             name: :idx_ocsf_network_activity_direction_time
           )

    create index(:ocsf_network_activity, [:dst_service_label, :time],
             prefix: "platform",
             name: :idx_ocsf_network_activity_dst_service_time
           )

    create index(:ocsf_network_activity, [:src_hosting_provider, :time],
             prefix: "platform",
             name: :idx_ocsf_network_activity_src_provider_time
           )

    create index(:ocsf_network_activity, [:dst_hosting_provider, :time],
             prefix: "platform",
             name: :idx_ocsf_network_activity_dst_provider_time
           )

    execute("""
    CREATE TABLE IF NOT EXISTS platform.netflow_provider_dataset_snapshots (
      id UUID PRIMARY KEY,
      source_url TEXT NOT NULL,
      source_etag TEXT,
      source_sha256 TEXT,
      fetched_at TIMESTAMPTZ NOT NULL,
      promoted_at TIMESTAMPTZ,
      is_active BOOLEAN NOT NULL DEFAULT FALSE,
      record_count INTEGER NOT NULL DEFAULT 0,
      metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS netflow_provider_dataset_single_active_idx
      ON platform.netflow_provider_dataset_snapshots ((1))
      WHERE is_active
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS platform.netflow_provider_cidrs (
      snapshot_id UUID NOT NULL REFERENCES platform.netflow_provider_dataset_snapshots(id) ON DELETE CASCADE,
      cidr CIDR NOT NULL,
      provider TEXT NOT NULL,
      service TEXT,
      region TEXT,
      ip_version TEXT,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (snapshot_id, cidr, provider)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS netflow_provider_cidrs_snapshot_provider_idx
      ON platform.netflow_provider_cidrs (snapshot_id, provider)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS netflow_provider_cidrs_cidr_idx
      ON platform.netflow_provider_cidrs USING gist (cidr inet_ops)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS platform.netflow_oui_dataset_snapshots (
      id UUID PRIMARY KEY,
      source_url TEXT NOT NULL,
      source_etag TEXT,
      source_sha256 TEXT,
      fetched_at TIMESTAMPTZ NOT NULL,
      promoted_at TIMESTAMPTZ,
      is_active BOOLEAN NOT NULL DEFAULT FALSE,
      record_count INTEGER NOT NULL DEFAULT 0,
      metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS netflow_oui_dataset_single_active_idx
      ON platform.netflow_oui_dataset_snapshots ((1))
      WHERE is_active
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS platform.netflow_oui_prefixes (
      snapshot_id UUID NOT NULL REFERENCES platform.netflow_oui_dataset_snapshots(id) ON DELETE CASCADE,
      oui_prefix_int INTEGER NOT NULL,
      oui_prefix_hex TEXT NOT NULL,
      organization TEXT NOT NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (snapshot_id, oui_prefix_int)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS netflow_oui_prefixes_snapshot_idx
      ON platform.netflow_oui_prefixes (snapshot_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS netflow_oui_prefixes_int_idx
      ON platform.netflow_oui_prefixes (oui_prefix_int)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.netflow_oui_prefixes_int_idx")
    execute("DROP INDEX IF EXISTS platform.netflow_oui_prefixes_snapshot_idx")
    execute("DROP TABLE IF EXISTS platform.netflow_oui_prefixes")
    execute("DROP INDEX IF EXISTS platform.netflow_oui_dataset_single_active_idx")
    execute("DROP TABLE IF EXISTS platform.netflow_oui_dataset_snapshots")

    execute("DROP INDEX IF EXISTS platform.netflow_provider_cidrs_cidr_idx")
    execute("DROP INDEX IF EXISTS platform.netflow_provider_cidrs_snapshot_provider_idx")
    execute("DROP TABLE IF EXISTS platform.netflow_provider_cidrs")
    execute("DROP INDEX IF EXISTS platform.netflow_provider_dataset_single_active_idx")
    execute("DROP TABLE IF EXISTS platform.netflow_provider_dataset_snapshots")

    drop_if_exists index(:ocsf_network_activity, [:dst_hosting_provider, :time],
                     prefix: "platform",
                     name: :idx_ocsf_network_activity_dst_provider_time
                   )

    drop_if_exists index(:ocsf_network_activity, [:src_hosting_provider, :time],
                     prefix: "platform",
                     name: :idx_ocsf_network_activity_src_provider_time
                   )

    drop_if_exists index(:ocsf_network_activity, [:dst_service_label, :time],
                     prefix: "platform",
                     name: :idx_ocsf_network_activity_dst_service_time
                   )

    drop_if_exists index(:ocsf_network_activity, [:direction_label, :time],
                     prefix: "platform",
                     name: :idx_ocsf_network_activity_direction_time
                   )

    alter table(:ocsf_network_activity, prefix: "platform") do
      remove :dst_mac_vendor_source
      remove :dst_mac_vendor
      remove :src_mac_vendor_source
      remove :src_mac_vendor
      remove :dst_mac
      remove :src_mac
      remove :dst_hosting_provider_source
      remove :dst_hosting_provider
      remove :src_hosting_provider_source
      remove :src_hosting_provider
      remove :direction_source
      remove :direction_label
      remove :dst_service_source
      remove :dst_service_label
      remove :tcp_flags_source
      remove :tcp_flags_labels
      remove :protocol_source
    end
  end
end
