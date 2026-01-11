defmodule ServiceRadar.Repo.TenantMigrations.AddOcsfAndIdentityTables do
  @moduledoc """
  Creates OCSF device inventory and identity/reconciliation tables in tenant schemas.

  These tables support the device identity reconciliation engine (DIRE) and
  OCSF-compliant device inventory tracking.
  """

  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    # ============================================================================
    # Drop existing OCSF tables to recreate with OCSF v1.7.0 schema
    # CASCADE drops dependent foreign key constraints
    # ============================================================================
    execute "DROP TABLE IF EXISTS #{schema}.ocsf_agents CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.ocsf_devices CASCADE"

    # ============================================================================
    # OCSF Device Inventory (OCSF v1.7.0 aligned)
    # ============================================================================

    execute """
    CREATE TABLE #{schema}.ocsf_devices (
      uid                 TEXT              PRIMARY KEY,
      type_id             INTEGER           NOT NULL DEFAULT 0,
      type                TEXT,
      name                TEXT,
      hostname            TEXT,
      ip                  TEXT,
      mac                 TEXT,
      uid_alt             TEXT,
      vendor_name         TEXT,
      model               TEXT,
      domain              TEXT,
      zone                TEXT,
      subnet_uid          TEXT,
      vlan_uid            TEXT,
      region              TEXT,
      first_seen_time     TIMESTAMPTZ,
      last_seen_time      TIMESTAMPTZ,
      created_time        TIMESTAMPTZ       NOT NULL DEFAULT now(),
      modified_time       TIMESTAMPTZ       NOT NULL DEFAULT now(),
      risk_level_id       INTEGER,
      risk_level          TEXT,
      risk_score          INTEGER,
      is_managed          BOOLEAN,
      is_compliant        BOOLEAN,
      is_trusted          BOOLEAN,
      os                  JSONB,
      hw_info             JSONB,
      network_interfaces  JSONB,
      owner               JSONB,
      org                 JSONB,
      groups              JSONB,
      agent_list          JSONB,
      gateway_id          TEXT,
      agent_id            TEXT,
      discovery_sources   TEXT[],
      is_available        BOOLEAN,
      group_id            UUID,
      tenant_id           UUID              NOT NULL,
      metadata            JSONB
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_ip ON #{schema}.ocsf_devices (ip)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_type_id ON #{schema}.ocsf_devices (type_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_last_seen ON #{schema}.ocsf_devices (last_seen_time)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_vendor ON #{schema}.ocsf_devices (vendor_name)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_hostname_trgm ON #{schema}.ocsf_devices USING gin (hostname gin_trgm_ops)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_ip_trgm ON #{schema}.ocsf_devices USING gin (ip gin_trgm_ops)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_name_trgm ON #{schema}.ocsf_devices USING gin (name gin_trgm_ops)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_os_gin ON #{schema}.ocsf_devices USING gin (os)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_metadata_gin ON #{schema}.ocsf_devices USING gin (metadata)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_group_id ON #{schema}.ocsf_devices (group_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_devices_tenant_id ON #{schema}.ocsf_devices (tenant_id)"

    # ============================================================================
    # OCSF Agent Registry (OCSF v1.7.0 aligned)
    # ============================================================================

    execute """
    CREATE TABLE #{schema}.ocsf_agents (
      uid                 TEXT              PRIMARY KEY,
      name                TEXT,
      type_id             INTEGER           NOT NULL DEFAULT 0,
      type                TEXT,
      version             TEXT,
      vendor_name         TEXT,
      uid_alt             TEXT,
      policies            JSONB,
      gateway_id          TEXT,
      device_uid          TEXT,
      capabilities        TEXT[],
      host                TEXT,
      port                INTEGER,
      spiffe_identity     TEXT,
      status              TEXT              NOT NULL DEFAULT 'connecting',
      is_healthy          BOOLEAN           NOT NULL DEFAULT true,
      tenant_id           UUID              NOT NULL,
      first_seen_time     TIMESTAMPTZ,
      last_seen_time      TIMESTAMPTZ,
      created_time        TIMESTAMPTZ       NOT NULL DEFAULT now(),
      modified_time       TIMESTAMPTZ       NOT NULL DEFAULT now(),
      metadata            JSONB
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_agents_gateway_id ON #{schema}.ocsf_agents (gateway_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_agents_type_id ON #{schema}.ocsf_agents (type_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_agents_last_seen ON #{schema}.ocsf_agents (last_seen_time)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_agents_host ON #{schema}.ocsf_agents (host)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_agents_status ON #{schema}.ocsf_agents (status)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_agents_tenant_id ON #{schema}.ocsf_agents (tenant_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_agents_device_uid ON #{schema}.ocsf_agents (device_uid)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_agents_capabilities ON #{schema}.ocsf_agents USING gin (capabilities)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_agents_name_trgm ON #{schema}.ocsf_agents USING gin (name gin_trgm_ops)"

    # ============================================================================
    # Device Groups
    # ============================================================================

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.device_groups (
      id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      tenant_id       UUID NOT NULL,
      name            VARCHAR(255) NOT NULL,
      "desc"          TEXT,
      type            VARCHAR(50) NOT NULL DEFAULT 'custom',
      parent_id       UUID REFERENCES #{schema}.device_groups(id) ON DELETE SET NULL,
      metadata        JSONB DEFAULT '{}'::jsonb,
      device_count    INTEGER DEFAULT 0,
      created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      CONSTRAINT device_groups_unique_name_per_tenant UNIQUE (tenant_id, name),
      CONSTRAINT device_groups_valid_type CHECK (type IN ('location', 'department', 'environment', 'function', 'custom'))
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_device_groups_tenant_id ON #{schema}.device_groups(tenant_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_device_groups_type ON #{schema}.device_groups(type)"
    execute "CREATE INDEX IF NOT EXISTS idx_device_groups_parent_id ON #{schema}.device_groups(parent_id)"

    # ============================================================================
    # Identity & Reconciliation Tables (DIRE)
    # ============================================================================

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.subnet_policies (
      subnet_id        UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
      cidr             CIDR            NOT NULL,
      classification   TEXT            NOT NULL DEFAULT 'dynamic',
      promotion_rules  JSONB           NOT NULL DEFAULT '{}'::jsonb,
      reaper_profile   TEXT            NOT NULL DEFAULT 'default',
      allow_ip_as_id   BOOLEAN         NOT NULL DEFAULT FALSE,
      created_at       TIMESTAMPTZ     NOT NULL DEFAULT now(),
      updated_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
    )
    """

    execute "CREATE UNIQUE INDEX IF NOT EXISTS idx_subnet_policies_cidr ON #{schema}.subnet_policies (cidr)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.fingerprints (
      fingerprint_id   UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
      hash             TEXT            NOT NULL,
      os_family        TEXT,
      ports            JSONB,
      host_label       TEXT,
      first_seen       TIMESTAMPTZ     NOT NULL DEFAULT now(),
      last_seen        TIMESTAMPTZ     NOT NULL DEFAULT now(),
      metadata         JSONB           NOT NULL DEFAULT '{}'::jsonb
    )
    """

    execute "CREATE UNIQUE INDEX IF NOT EXISTS idx_fingerprints_hash ON #{schema}.fingerprints (hash)"
    execute "CREATE INDEX IF NOT EXISTS idx_fingerprints_host_label ON #{schema}.fingerprints (host_label)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.network_sightings (
      sighting_id      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
      partition        TEXT            NOT NULL,
      ip               TEXT            NOT NULL,
      subnet_id        UUID            REFERENCES #{schema}.subnet_policies(subnet_id) ON DELETE SET NULL,
      source           TEXT            NOT NULL,
      status           TEXT            NOT NULL DEFAULT 'active',
      first_seen       TIMESTAMPTZ     NOT NULL DEFAULT now(),
      last_seen        TIMESTAMPTZ     NOT NULL DEFAULT now(),
      ttl_expires_at   TIMESTAMPTZ,
      fingerprint_id   UUID            REFERENCES #{schema}.fingerprints(fingerprint_id) ON DELETE SET NULL,
      metadata         JSONB           NOT NULL DEFAULT '{}'::jsonb,
      created_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
    )
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_network_sightings_active_per_ip
    ON #{schema}.network_sightings (partition, ip)
    WHERE status = 'active'
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_network_sightings_subnet_status_expiry
    ON #{schema}.network_sightings (subnet_id, status, ttl_expires_at)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_network_sightings_fingerprint
    ON #{schema}.network_sightings (fingerprint_id)
    WHERE fingerprint_id IS NOT NULL
    """

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.device_identifiers (
      id               SERIAL          PRIMARY KEY,
      device_id        TEXT            NOT NULL,
      identifier_type  TEXT            NOT NULL,
      identifier_value TEXT            NOT NULL,
      partition        TEXT            NOT NULL DEFAULT 'default',
      confidence       TEXT            NOT NULL DEFAULT 'strong',
      source           TEXT,
      first_seen       TIMESTAMPTZ     NOT NULL DEFAULT now(),
      last_seen        TIMESTAMPTZ     NOT NULL DEFAULT now(),
      verified         BOOLEAN         NOT NULL DEFAULT FALSE,
      metadata         JSONB           NOT NULL DEFAULT '{}'::jsonb,
      UNIQUE (identifier_type, identifier_value, partition)
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_device_identifiers_device ON #{schema}.device_identifiers(device_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_device_identifiers_lookup ON #{schema}.device_identifiers(identifier_type, identifier_value)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.sighting_events (
      event_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
      sighting_id      UUID            NOT NULL REFERENCES #{schema}.network_sightings(sighting_id) ON DELETE CASCADE,
      device_id        TEXT,
      event_type       TEXT            NOT NULL,
      actor            TEXT            NOT NULL DEFAULT 'system',
      details          JSONB           NOT NULL DEFAULT '{}'::jsonb,
      created_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_sighting_events_sighting ON #{schema}.sighting_events (sighting_id, created_at DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_sighting_events_device ON #{schema}.sighting_events (device_id, created_at DESC)"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.merge_audit (
      event_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
      from_device_id   TEXT            NOT NULL,
      to_device_id     TEXT            NOT NULL,
      reason           TEXT,
      confidence_score NUMERIC,
      source           TEXT,
      details          JSONB           NOT NULL DEFAULT '{}'::jsonb,
      created_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_merge_audit_to_device ON #{schema}.merge_audit (to_device_id, created_at DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_merge_audit_from_device ON #{schema}.merge_audit (from_device_id, created_at DESC)"
  end

  def down do
    schema = prefix() || "public"

    # Drop in reverse order due to foreign key constraints
    execute "DROP TABLE IF EXISTS #{schema}.merge_audit CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.sighting_events CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.device_identifiers CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.network_sightings CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.fingerprints CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.subnet_policies CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.device_groups CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.ocsf_agents CASCADE"
    execute "DROP TABLE IF EXISTS #{schema}.ocsf_devices CASCADE"
  end
end
