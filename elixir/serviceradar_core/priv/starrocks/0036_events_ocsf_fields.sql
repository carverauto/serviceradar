-- The rest of the CNPG ocsf_events row. With events cut over, EventWriter writes
-- an event to the warehouse only, so a field this table does not store is lost:
-- the actor and endpoint documents, status_code, status_detail, log_version,
-- the producer's raw payload and the ingest time. The documents are JSON text,
-- like the 0018 documents, and are read the same way.
-- None of these is bounded in CNPG. Every one arrives inside a single NATS
-- message, which the shipped broker caps at 1 MiB (max_payload default; the
-- chart does not raise it), so VARCHAR(1048576) holds any value that can arrive
-- and nothing is truncated. A value past it is dropped from its field and
-- reported, exactly as an oversized 0018 document is, so the event still lands.
-- Fresh installs get these from 0004; ALTER covers tables created earlier. A
-- row written before this file has NULL in each, as an absent field reads.
-- As in 0018, SchemaMigrator awaits each ADD COLUMN before the next, and the
-- events_hourly view stays active across them.
ALTER TABLE serviceradar.events ADD COLUMN status_code VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN status_detail VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN log_version VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN actor VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN src_endpoint VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN dst_endpoint VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN raw_data VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN created_at DATETIME NULL;
