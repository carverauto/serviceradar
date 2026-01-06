defmodule ServiceRadar.Repo.Migrations.AddOcsfNetworkActivity do
  @moduledoc """
  Creates the ocsf_network_activity hypertable for storing OCSF Network Activity events.

  This table follows the OCSF v1.3.0 Network Activity schema (class_uid: 4001)
  in the Network Activity category (category_uid: 4).

  ## Use Cases
  - Network sweep/discovery results (activity_id: 99 Scan)
  - NetFlow traffic data (activity_id: 6 Traffic)
  - Connection events (activity_id: 1 Open, 2 Close, etc.)

  ## OCSF Activity IDs for Network Activity
  - 1: Open (new connection)
  - 2: Close (connection terminated)
  - 3: Reset (abnormally terminated)
  - 4: Fail (timeout/routing issue)
  - 5: Refuse (port not open)
  - 6: Traffic (network traffic report)
  - 7: Listen (endpoint listening)
  - 99: Other/Scan (custom for discovery)
  """

  use Ecto.Migration

  def up do
    # Create the ocsf_network_activity table
    create table(:ocsf_network_activity, primary_key: false) do
      # Primary key is (time, id) for TimescaleDB hypertable
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :time, :utc_datetime_usec, null: false

      # OCSF Classification Fields (required)
      add :class_uid, :integer, null: false, default: 4001
      add :category_uid, :integer, null: false, default: 4
      add :type_uid, :bigint, null: false
      add :activity_id, :integer, null: false
      add :severity_id, :integer, null: false, default: 1

      # OCSF Content Fields
      add :message, :text
      add :severity, :text
      add :activity_name, :text

      # Action (for firewall/policy events)
      add :action_id, :integer
      add :action, :text

      # Status
      add :status_id, :integer
      add :status, :text
      add :status_code, :text
      add :status_detail, :text

      # OCSF Metadata (required object)
      add :metadata, :map, null: false, default: %{}

      # OCSF Observables (array of observable objects)
      add :observables, {:array, :map}, default: []

      # Source Endpoint
      add :src_endpoint, :map, default: %{}

      # Destination Endpoint
      add :dst_endpoint, :map, default: %{}

      # Network Connection Info
      add :connection_info, :map, default: %{}

      # Traffic Statistics
      add :traffic, :map, default: %{}

      # Protocol
      add :protocol_name, :text
      add :protocol_num, :integer

      # Direction
      add :direction, :text
      add :direction_id, :integer

      # Duration (for connection/scan events)
      add :duration, :bigint

      # Device that reported the event
      add :device, :map, default: %{}

      # Actor/Source information
      add :actor, :map, default: %{}

      # Discovery/Scan specific fields
      add :scan_type, :text
      add :ports_scanned, {:array, :integer}, default: []
      add :ports_open, {:array, :integer}, default: []
      add :icmp_available, :boolean
      add :response_time_ns, :bigint

      # Unmapped data for extensibility
      add :unmapped, :map, default: %{}

      # Raw data for debugging/replay
      add :raw_data, :text

      # Multi-tenancy
      add :tenant_id, :uuid, null: false

      # Poller/Agent tracking
      add :poller_id, :text
      add :agent_id, :text

      # Record timestamp
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # Create TimescaleDB hypertable for efficient time-series queries
    execute """
    SELECT create_hypertable('ocsf_network_activity', 'time',
      chunk_time_interval => INTERVAL '1 day',
      if_not_exists => TRUE)
    """

    # Create indexes for common query patterns
    create index(:ocsf_network_activity, [:tenant_id, :time])
    create index(:ocsf_network_activity, [:activity_id])
    create index(:ocsf_network_activity, [:severity_id])
    create index(:ocsf_network_activity, [:poller_id], where: "poller_id IS NOT NULL")
    create index(:ocsf_network_activity, [:agent_id], where: "agent_id IS NOT NULL")

    # GIN indexes for JSONB queries
    execute "CREATE INDEX ocsf_network_activity_src_endpoint_idx ON ocsf_network_activity USING gin (src_endpoint)"
    execute "CREATE INDEX ocsf_network_activity_dst_endpoint_idx ON ocsf_network_activity USING gin (dst_endpoint)"
    execute "CREATE INDEX ocsf_network_activity_metadata_idx ON ocsf_network_activity USING gin (metadata)"

    # Partial index for scan events (sweep data)
    create index(:ocsf_network_activity, [:time, :tenant_id],
      where: "activity_id = 99",
      name: :ocsf_network_activity_scan_idx
    )

    # Partial index for traffic events (netflow data)
    create index(:ocsf_network_activity, [:time, :tenant_id],
      where: "activity_id = 6",
      name: :ocsf_network_activity_traffic_idx
    )
  end

  def down do
    drop table(:ocsf_network_activity)
  end
end
