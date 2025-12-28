-- Create tenant_cas table for per-tenant certificate authorities
CREATE TABLE IF NOT EXISTS tenant_cas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- Certificate data
    certificate_pem TEXT NOT NULL,
    private_key_pem TEXT NOT NULL,  -- Encrypted by AshCloak
    serial_number VARCHAR(64) NOT NULL,
    next_child_serial INTEGER NOT NULL DEFAULT 1,
    subject_cn VARCHAR(255) NOT NULL,

    -- Validity
    not_before TIMESTAMPTZ NOT NULL,
    not_after TIMESTAMPTZ NOT NULL,

    -- Status
    status VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'revoked', 'expired')),
    revoked_at TIMESTAMPTZ,
    revocation_reason TEXT,

    -- Timestamps
    inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for tenant lookup
CREATE INDEX idx_tenant_cas_tenant_id ON tenant_cas(tenant_id);

-- Index for active CA lookup
CREATE INDEX idx_tenant_cas_tenant_active ON tenant_cas(tenant_id, status)
    WHERE status = 'active';

-- Only one active CA per tenant
CREATE UNIQUE INDEX idx_tenant_cas_unique_active
    ON tenant_cas(tenant_id)
    WHERE status = 'active';

-- Add trigger to update updated_at
CREATE OR REPLACE FUNCTION update_tenant_cas_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_tenant_cas_updated_at
    BEFORE UPDATE ON tenant_cas
    FOR EACH ROW
    EXECUTE FUNCTION update_tenant_cas_updated_at();

COMMENT ON TABLE tenant_cas IS 'Per-tenant certificate authorities for edge component isolation';
COMMENT ON COLUMN tenant_cas.private_key_pem IS 'Encrypted CA private key (AshCloak)';
COMMENT ON COLUMN tenant_cas.next_child_serial IS 'Next serial number for child certificates';
