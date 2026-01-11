defmodule ServiceRadar.Repo.TenantMigrations.AddTelemetryTables do
  @moduledoc """
  Creates telemetry and discovery tables in tenant schemas.

  These tables use TimescaleDB hypertables for time-series data.
  They were previously created only in public schema but should be
  tenant-isolated for proper data separation.
  """

  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    # ============================================================================
    # Generic telemetry hypertables
    # ============================================================================

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.timeseries_metrics (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT              NOT NULL,
      agent_id            TEXT,
      metric_name         TEXT              NOT NULL,
      metric_type         TEXT              NOT NULL,
      device_id           TEXT,
      value               DOUBLE PRECISION  NOT NULL,
      unit                TEXT,
      tags                JSONB,
      partition           TEXT,
      scale               DOUBLE PRECISION,
      is_delta            BOOLEAN           DEFAULT FALSE,
      target_device_ip    TEXT,
      if_index            INTEGER,
      metadata            JSONB,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.timeseries_metrics', 'timestamp', if_not_exists => TRUE)"
    execute "CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_device_time ON #{schema}.timeseries_metrics (device_id, timestamp DESC)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.cpu_metrics (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT              NOT NULL,
      agent_id            TEXT,
      host_id             TEXT,
      core_id             INTEGER,
      usage_percent       DOUBLE PRECISION,
      frequency_hz        DOUBLE PRECISION,
      label               TEXT,
      cluster             TEXT,
      device_id           TEXT,
      partition           TEXT,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.cpu_metrics', 'timestamp', if_not_exists => TRUE)"
    execute "CREATE INDEX IF NOT EXISTS idx_cpu_metrics_device_time ON #{schema}.cpu_metrics (device_id, timestamp DESC)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.cpu_cluster_metrics (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT,
      agent_id            TEXT,
      host_id             TEXT,
      cluster             TEXT,
      frequency_hz        DOUBLE PRECISION,
      device_id           TEXT,
      partition           TEXT,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.cpu_cluster_metrics', 'timestamp', if_not_exists => TRUE)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.disk_metrics (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT,
      agent_id            TEXT,
      host_id             TEXT,
      mount_point         TEXT,
      device_name         TEXT,
      total_bytes         BIGINT,
      used_bytes          BIGINT,
      available_bytes     BIGINT,
      usage_percent       DOUBLE PRECISION,
      device_id           TEXT,
      partition           TEXT,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.disk_metrics', 'timestamp', if_not_exists => TRUE)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.memory_metrics (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT,
      agent_id            TEXT,
      host_id             TEXT,
      total_bytes         BIGINT,
      used_bytes          BIGINT,
      available_bytes     BIGINT,
      usage_percent       DOUBLE PRECISION,
      device_id           TEXT,
      partition           TEXT,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.memory_metrics', 'timestamp', if_not_exists => TRUE)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.process_metrics (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT,
      agent_id            TEXT,
      host_id             TEXT,
      pid                 INTEGER,
      name                TEXT,
      cpu_usage           REAL,
      memory_usage        BIGINT,
      status              TEXT,
      start_time          TEXT,
      device_id           TEXT,
      partition           TEXT,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.process_metrics', 'timestamp', if_not_exists => TRUE)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.netflow_metrics (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT,
      agent_id            TEXT,
      device_id           TEXT,
      flow_direction      TEXT,
      src_addr            TEXT,
      dst_addr            TEXT,
      src_port            INTEGER,
      dst_port            INTEGER,
      protocol            INTEGER,
      packets             BIGINT,
      octets              BIGINT,
      sampler_address     TEXT,
      input_snmp          INTEGER,
      output_snmp         INTEGER,
      metadata            JSONB,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.netflow_metrics', 'timestamp', if_not_exists => TRUE)"

    # ============================================================================
    # Discovery tables
    # ============================================================================

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.sweep_host_states (
      host_ip             TEXT              NOT NULL,
      gateway_id          TEXT              NOT NULL,
      agent_id            TEXT              NOT NULL,
      partition           TEXT              NOT NULL,
      network_cidr        TEXT,
      hostname            TEXT,
      mac                 TEXT,
      icmp_available      BOOLEAN,
      icmp_response_time_ns BIGINT,
      icmp_packet_loss    DOUBLE PRECISION,
      tcp_ports_scanned   JSONB,
      tcp_ports_open      JSONB,
      port_scan_results   JSONB,
      last_sweep_time     TIMESTAMPTZ       NOT NULL,
      first_seen          TIMESTAMPTZ,
      metadata            JSONB,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now(),
      PRIMARY KEY (host_ip, gateway_id, partition, last_sweep_time)
    )
    """

    execute "SELECT create_hypertable('#{schema}.sweep_host_states', 'last_sweep_time', if_not_exists => TRUE)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.discovered_interfaces (
      timestamp           TIMESTAMPTZ       NOT NULL,
      agent_id            TEXT,
      gateway_id          TEXT,
      device_ip           TEXT,
      device_id           TEXT,
      if_index            INTEGER,
      if_name             TEXT,
      if_descr            TEXT,
      if_alias            TEXT,
      if_speed            BIGINT,
      if_phys_address     TEXT,
      ip_addresses        TEXT[],
      if_admin_status     INTEGER,
      if_oper_status      INTEGER,
      metadata            JSONB,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.discovered_interfaces', 'timestamp', if_not_exists => TRUE)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.topology_discovery_events (
      timestamp                TIMESTAMPTZ   NOT NULL,
      agent_id                 TEXT,
      gateway_id               TEXT,
      local_device_ip          TEXT,
      local_device_id          TEXT,
      local_if_index           INTEGER,
      local_if_name            TEXT,
      protocol_type            TEXT,
      neighbor_chassis_id      TEXT,
      neighbor_port_id         TEXT,
      neighbor_port_descr      TEXT,
      neighbor_system_name     TEXT,
      neighbor_management_addr TEXT,
      neighbor_bgp_router_id   TEXT,
      neighbor_ip_address      TEXT,
      neighbor_as              INTEGER,
      bgp_session_state        TEXT,
      metadata                 JSONB,
      created_at               TIMESTAMPTZ   NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.topology_discovery_events', 'timestamp', if_not_exists => TRUE)"

    # ============================================================================
    # Device tables
    # ============================================================================

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.device_updates (
      observed_at         TIMESTAMPTZ       NOT NULL,
      agent_id            TEXT              NOT NULL,
      gateway_id          TEXT              NOT NULL,
      partition           TEXT              NOT NULL,
      device_id           TEXT              NOT NULL,
      discovery_source    TEXT              NOT NULL,
      ip                  TEXT,
      mac                 TEXT,
      hostname            TEXT,
      available           BOOLEAN,
      metadata            JSONB,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.device_updates', 'observed_at', if_not_exists => TRUE)"
    execute "CREATE INDEX IF NOT EXISTS idx_device_updates_device_time ON #{schema}.device_updates (device_id, observed_at DESC)"

    # ============================================================================
    # Service history tables
    # ============================================================================

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.gateway_history (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT              NOT NULL,
      is_healthy          BOOLEAN           NOT NULL,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.gateway_history', 'timestamp', if_not_exists => TRUE)"
    execute "CREATE INDEX IF NOT EXISTS idx_gateway_history_id_time ON #{schema}.gateway_history (gateway_id, timestamp DESC)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.service_status (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT              NOT NULL,
      agent_id            TEXT,
      service_name        TEXT              NOT NULL,
      service_type        TEXT,
      available           BOOLEAN           NOT NULL,
      message             TEXT,
      details             TEXT,
      partition           TEXT,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.service_status', 'timestamp', if_not_exists => TRUE)"
    execute "CREATE INDEX IF NOT EXISTS idx_service_status_identity ON #{schema}.service_status (gateway_id, service_name, timestamp DESC)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.services (
      timestamp           TIMESTAMPTZ       NOT NULL,
      gateway_id          TEXT              NOT NULL,
      agent_id            TEXT,
      service_name        TEXT              NOT NULL,
      service_type        TEXT,
      config              JSONB             DEFAULT '{}'::jsonb,
      partition           TEXT,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.services', 'timestamp', if_not_exists => TRUE)"

    # ============================================================================
    # Events table
    # ============================================================================

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.events (
      event_timestamp    TIMESTAMPTZ   NOT NULL,
      specversion        TEXT,
      id                 TEXT          NOT NULL,
      source             TEXT,
      type               TEXT,
      datacontenttype    TEXT,
      subject            TEXT,
      remote_addr        TEXT,
      host               TEXT,
      level              INTEGER,
      severity           TEXT,
      short_message      TEXT,
      version            TEXT,
      raw_data           TEXT,
      created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
      PRIMARY KEY (event_timestamp, id)
    )
    """

    execute "SELECT create_hypertable('#{schema}.events', 'event_timestamp', if_not_exists => TRUE)"
    execute "CREATE UNIQUE INDEX IF NOT EXISTS idx_events_id_unique ON #{schema}.events (id, event_timestamp)"
    execute "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON #{schema}.events (event_timestamp DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_events_subject ON #{schema}.events (subject)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.rperf_metrics (
      timestamp      TIMESTAMPTZ   NOT NULL,
      gateway_id     TEXT          NOT NULL,
      service_name   TEXT          NOT NULL,
      message        TEXT,
      created_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('#{schema}.rperf_metrics', 'timestamp', if_not_exists => TRUE)"
    execute "CREATE INDEX IF NOT EXISTS idx_rperf_metrics_gateway_time ON #{schema}.rperf_metrics (gateway_id, timestamp DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_rperf_metrics_service ON #{schema}.rperf_metrics (service_name)"

    # ============================================================================
    # Device capability tables
    # ============================================================================

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.device_capabilities (
      event_id            TEXT              NOT NULL,
      device_id           TEXT              NOT NULL,
      service_id          TEXT              DEFAULT '',
      service_type        TEXT              DEFAULT '',
      capability          TEXT              NOT NULL,
      state               TEXT              DEFAULT 'unknown',
      enabled             BOOLEAN           DEFAULT TRUE,
      last_checked        TIMESTAMPTZ       DEFAULT now(),
      last_success        TIMESTAMPTZ,
      last_failure        TIMESTAMPTZ,
      failure_reason      TEXT              DEFAULT '',
      metadata            JSONB             DEFAULT '{}'::jsonb,
      recorded_by         TEXT              DEFAULT 'system',
      PRIMARY KEY (event_id, last_checked)
    )
    """

    execute "SELECT create_hypertable('#{schema}.device_capabilities', 'last_checked', if_not_exists => TRUE)"
    execute "CREATE INDEX IF NOT EXISTS idx_device_capabilities_lookup ON #{schema}.device_capabilities (device_id, capability, service_id, last_checked DESC)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.device_capability_registry (
      device_id           TEXT              NOT NULL,
      capability          TEXT              NOT NULL,
      service_id          TEXT              DEFAULT '',
      service_type        TEXT              DEFAULT '',
      state               TEXT              DEFAULT 'unknown',
      enabled             BOOLEAN           DEFAULT TRUE,
      last_checked        TIMESTAMPTZ,
      last_success        TIMESTAMPTZ,
      last_failure        TIMESTAMPTZ,
      failure_reason      TEXT              DEFAULT '',
      metadata            JSONB             DEFAULT '{}'::jsonb,
      recorded_by         TEXT              DEFAULT 'system',
      updated_at          TIMESTAMPTZ       NOT NULL DEFAULT now(),
      PRIMARY KEY (device_id, capability, service_id)
    )
    """
  end

  def down do
    schema = prefix() || "public"

    # Drop tables in reverse order
    execute "DROP TABLE IF EXISTS #{schema}.device_capability_registry CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.device_capabilities CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.rperf_metrics CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.events CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.services CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.service_status CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.gateway_history CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.device_updates CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.topology_discovery_events CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.discovered_interfaces CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.sweep_host_states CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.netflow_metrics CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.process_metrics CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.memory_metrics CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.disk_metrics CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.cpu_cluster_metrics CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.cpu_metrics CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.timeseries_metrics CASCADE"
  end
end
