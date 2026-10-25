ALTER TABLE serviceradar.exposure_facts
ADD COLUMN device_lifecycle_seq BIGINT NOT NULL DEFAULT "0";

-- Permanent lifecycle watermark. Restoration advances state without deleting
-- the earlier retirement fence or changing the shared fleet ordinal.
CREATE TABLE IF NOT EXISTS serviceradar.exposure_retired_ordinals (
  device_ord BIGINT NOT NULL,
  transition_seq BIGINT NOT NULL,
  transition_xid BIGINT NOT NULL,
  state TINYINT NOT NULL,
  updated_at DATETIME NOT NULL,
  retired_seq BIGINT NOT NULL,
  retired_xid BIGINT,
  retired_at DATETIME
)
PRIMARY KEY (device_ord)
DISTRIBUTED BY HASH(device_ord) BUCKETS 4
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true"
);
