-- OCSF Network Activity hypertable for flow telemetry
-- Follows OCSF 1.7.0 network_activity class schema
-- Reference: https://schema.ocsf.io/1.7.0/classes/network_activity

CREATE TABLE IF NOT EXISTS ocsf_network_activity (
    -- OCSF Core Fields
    time                 TIMESTAMPTZ       NOT NULL,  -- Primary timestamp (flow end time or receive time)
    class_uid            INTEGER           NOT NULL DEFAULT 4001,
    category_uid         INTEGER           NOT NULL DEFAULT 4,
    activity_id          INTEGER           NOT NULL DEFAULT 6,
    type_uid             INTEGER           NOT NULL DEFAULT 400106,
    severity_id          INTEGER           NOT NULL DEFAULT 1,

    -- Timestamps
    start_time           TIMESTAMPTZ,
    end_time             TIMESTAMPTZ,

    -- Source Endpoint (extracted for indexing and analytics)
    src_endpoint_ip      TEXT,
    src_endpoint_port    INTEGER,
    src_as_number        INTEGER,

    -- Destination Endpoint (extracted for indexing and analytics)
    dst_endpoint_ip      TEXT,
    dst_endpoint_port    INTEGER,
    dst_as_number        INTEGER,

    -- Connection Info (extracted for filtering)
    protocol_num         INTEGER,
    protocol_name        TEXT,
    tcp_flags            INTEGER,

    -- Traffic (extracted for aggregations)
    bytes_total          BIGINT,
    packets_total        BIGINT,
    bytes_in             BIGINT,
    bytes_out            BIGINT,

    -- Observer
    sampler_address      TEXT,

    -- Full OCSF payload (for complete event reconstruction)
    ocsf_payload         JSONB             NOT NULL,

    -- ServiceRadar metadata
    partition            TEXT              DEFAULT 'default',
    created_at           TIMESTAMPTZ       NOT NULL DEFAULT now()
);

-- Create hypertable partitioned on time
SELECT create_hypertable('ocsf_network_activity', 'time', if_not_exists => TRUE);

-- Indexes for common query patterns

-- Top talkers query (by source IP)
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_src_ip_time
    ON ocsf_network_activity (src_endpoint_ip, time DESC);

-- Top destinations query (by destination IP)
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_dst_ip_time
    ON ocsf_network_activity (dst_endpoint_ip, time DESC);

-- Protocol filtering
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_proto_time
    ON ocsf_network_activity (protocol_num, time DESC);

-- Source port filtering
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_src_port_time
    ON ocsf_network_activity (src_endpoint_port, time DESC)
    WHERE src_endpoint_port IS NOT NULL;

-- Destination port filtering (for top ports queries)
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_dst_port_time
    ON ocsf_network_activity (dst_endpoint_port, time DESC)
    WHERE dst_endpoint_port IS NOT NULL;

-- Sampler/exporter filtering
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_sampler_time
    ON ocsf_network_activity (sampler_address, time DESC);

-- GIN index for JSONB queries on full payload
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_payload_gin
    ON ocsf_network_activity USING gin (ocsf_payload);

-- Composite index optimized for top talkers aggregation
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_top_talkers
    ON ocsf_network_activity (time DESC, src_endpoint_ip, bytes_total);

-- Composite index optimized for top ports aggregation
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_top_ports
    ON ocsf_network_activity (time DESC, dst_endpoint_port, bytes_total);

-- Partition index
CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_partition
    ON ocsf_network_activity (partition, time DESC);

-- Comments for documentation
COMMENT ON TABLE ocsf_network_activity IS 'OCSF 1.7.0 Network Activity events from NetFlow/IPFIX collectors';
COMMENT ON COLUMN ocsf_network_activity.time IS 'Flow end time or receive time (ms since epoch)';
COMMENT ON COLUMN ocsf_network_activity.class_uid IS 'OCSF class UID (4001 = Network Activity)';
COMMENT ON COLUMN ocsf_network_activity.activity_id IS 'OCSF activity ID (6 = Traffic)';
COMMENT ON COLUMN ocsf_network_activity.type_uid IS 'OCSF type UID (400106 = Network Activity: Traffic)';
COMMENT ON COLUMN ocsf_network_activity.ocsf_payload IS 'Full OCSF event as JSON for complete event reconstruction';
COMMENT ON COLUMN ocsf_network_activity.bytes_total IS 'Total bytes transferred in flow';
COMMENT ON COLUMN ocsf_network_activity.packets_total IS 'Total packets transferred in flow';
