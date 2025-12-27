-- Device Groups table for organizing devices
-- OCSF-aligned group structure with hierarchical support

CREATE TABLE IF NOT EXISTS device_groups (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL,
    name            VARCHAR(255) NOT NULL,
    "desc"          TEXT,
    type            VARCHAR(50) NOT NULL DEFAULT 'custom',
    parent_id       UUID REFERENCES device_groups(id) ON DELETE SET NULL,
    metadata        JSONB DEFAULT '{}'::jsonb,
    device_count    INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT device_groups_unique_name_per_tenant UNIQUE (tenant_id, name),
    CONSTRAINT device_groups_valid_type CHECK (type IN ('location', 'department', 'environment', 'function', 'custom'))
);

-- Indexes for common queries
CREATE INDEX idx_device_groups_tenant_id ON device_groups(tenant_id);
CREATE INDEX idx_device_groups_type ON device_groups(type);
CREATE INDEX idx_device_groups_parent_id ON device_groups(parent_id);

-- Add group_id to ocsf_devices table
ALTER TABLE ocsf_devices ADD COLUMN IF NOT EXISTS group_id UUID REFERENCES device_groups(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_group_id ON ocsf_devices(group_id);

COMMENT ON TABLE device_groups IS 'Device groups for organizational hierarchy (OCSF Group aligned)';
COMMENT ON COLUMN device_groups.type IS 'Group type: location, department, environment, function, custom';
COMMENT ON COLUMN device_groups.parent_id IS 'Parent group ID for hierarchical organization';
