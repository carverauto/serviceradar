-- Free text in OTel spans, BMP routing events, and flow process attribution
-- observations is stored whole. Every value arrives inside one NATS message,
-- which the shipped broker caps at 1 MiB, so VARCHAR(1048576) holds whatever
-- can arrive (as in 0036 and 0037).
-- Protocol-bounded identifier columns (trace_id, span_id, parent_span_id,
-- router_id, router_ip, peer_ip, prefix, agent_id, container_id) keep their
-- width: a value past it is not a valid identifier, and EventWriter stores
-- NULL and counts it rather than a cut one.
-- Fresh installs get these widths from 0022, 0024, 0026, and 0031.
-- SchemaMigrator skips a MODIFY whose column already has this type, and awaits
-- each one before the next.
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN trace_state VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN service_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN service_version VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN service_instance VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN service_namespace VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN deployment_environment VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN scope_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN scope_version VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN status_message VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN ingest_identity VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN ingest_agent_id VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.otel_traces MODIFY COLUMN ingest_partition VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.bmp_routing_events MODIFY COLUMN event_type VARCHAR(1048576) NOT NULL;
ALTER TABLE serviceradar.bmp_routing_events MODIFY COLUMN message VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.bmp_routing_events MODIFY COLUMN raw_data VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.flow_process_attribution_observations MODIFY COLUMN comm VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.flow_process_attribution_observations MODIFY COLUMN cmdline VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.flow_process_attribution_observations MODIFY COLUMN executable_ownership VARCHAR(1048576) NULL;
