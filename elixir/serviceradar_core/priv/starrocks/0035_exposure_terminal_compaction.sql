-- Storage-only marker. Conditional live/snapshot after-images clear it; compaction
-- preserves the permanent key, state, sequence, xid, lifecycle and snapshot fence.
ALTER TABLE serviceradar.exposure_facts ADD COLUMN payload_compacted BOOLEAN NOT NULL DEFAULT "false";
