defmodule ServiceRadar.Repo.Migrations.CreateBgpRoutingInfo do
  use Ecto.Migration

  def up do
    # Create bgp_routing_info table
    create table(:bgp_routing_info, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :timestamp, :utc_datetime_usec, null: false
      add :source_protocol, :text, null: false
      add :as_path, {:array, :integer}, null: false
      add :bgp_communities, {:array, :integer}
      add :src_ip, :inet
      add :dst_ip, :inet
      add :total_bytes, :bigint, default: 0
      add :total_packets, :bigint, default: 0
      add :flow_count, :integer, default: 0
      add :metadata, :jsonb
      add :created_at, :utc_datetime_usec, default: fragment("(now() AT TIME ZONE 'utc')")
    end

    # Convert to TimescaleDB hypertable
    execute """
    SELECT create_hypertable(
      'platform.bgp_routing_info',
      'timestamp',
      chunk_time_interval => INTERVAL '1 day',
      if_not_exists => TRUE
    );
    """

    # Create GIN index on as_path for efficient array queries (@> operator)
    create index(:bgp_routing_info, [:as_path],
      name: :idx_bgp_routing_as_path,
      using: "GIN",
      prefix: "platform"
    )

    # Create GIN index on bgp_communities for efficient array queries
    create index(:bgp_routing_info, [:bgp_communities],
      name: :idx_bgp_routing_communities,
      using: "GIN",
      prefix: "platform"
    )

    # Create index on source_protocol and timestamp for filtering by source
    create index(:bgp_routing_info, [:source_protocol, :timestamp],
      name: :idx_bgp_routing_source,
      prefix: "platform"
    )

    # Create unique index for deduplication (ON CONFLICT support)
    # Uses time_bucket for 1-minute bucketing
    execute """
    CREATE UNIQUE INDEX idx_bgp_routing_dedup ON platform.bgp_routing_info (
      time_bucket('1 minute'::interval, timestamp),
      source_protocol,
      as_path,
      COALESCE(bgp_communities, ARRAY[]::integer[]),
      COALESCE(src_ip::text, ''),
      COALESCE(dst_ip::text, '')
    );
    """

    # Add bgp_observation_id column to netflow_metrics
    alter table(:netflow_metrics, prefix: "platform") do
      add :bgp_observation_id, :uuid
    end

    # Add foreign key constraint
    create constraint(:netflow_metrics, :fk_bgp_observation,
      foreign_key: [:bgp_observation_id],
      references: [:bgp_routing_info, :id],
      on_delete: :nilify_all,
      prefix: "platform"
    )

    # Create index on bgp_observation_id for efficient JOINs
    create index(:netflow_metrics, [:bgp_observation_id],
      name: :idx_netflow_bgp_observation,
      prefix: "platform"
    )
  end

  def down do
    # Drop indexes and constraints from netflow_metrics
    drop_if_exists index(:netflow_metrics, [:bgp_observation_id],
      name: :idx_netflow_bgp_observation,
      prefix: "platform"
    )

    drop_if_exists constraint(:netflow_metrics, :fk_bgp_observation, prefix: "platform")

    alter table(:netflow_metrics, prefix: "platform") do
      remove :bgp_observation_id
    end

    # Drop bgp_routing_info table (TimescaleDB will handle hypertable cleanup)
    drop_if_exists table(:bgp_routing_info, prefix: "platform")
  end
end
