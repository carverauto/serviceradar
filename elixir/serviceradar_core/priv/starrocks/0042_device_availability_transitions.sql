-- The merged device availability history (OpenSpec fix-device-availability-timeline,
-- design Decision 2). Not a Mix/Postgres migration; BUILD.bazel here says how these are
-- applied.
--
-- Column names are those of platform.device_availability_transitions, so a reader serves
-- either backend from the same row shape. EventWriter's AvailabilityTransitions processor
-- writes here, and only here, when StarRocks is enabled; otherwise it writes CNPG.
--
-- One row per change of a device's merged availability state: the device was from_state
-- from from_since (NULL when it had no earlier decision) until changed_at, when it became
-- to_state. The key is (device_uid, changed_at, to_state), the identity the publisher's
-- message id is derived from, so a redelivered or republished record upserts itself.
-- StarRocks requires the partition column in the primary key; device_uid leads the sort
-- key because the timeline reads one device over a window.
--
-- partition_live_number 365 is the warehouse's one-year telemetry retention default.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.device_availability_transitions (
  device_uid VARCHAR(256) NOT NULL,
  changed_at DATETIME NOT NULL,
  to_state VARCHAR(16) NOT NULL,
  from_state VARCHAR(16) NOT NULL,
  from_since DATETIME,
  authority_class VARCHAR(64),
  source_kind VARCHAR(128),
  reporter_agent_id VARCHAR(256),
  rule VARCHAR(128),
  conflict BOOLEAN NOT NULL,
  created_at DATETIME NOT NULL
)
PRIMARY KEY (device_uid, changed_at, to_state)
PARTITION BY date_trunc('day', changed_at)
DISTRIBUTED BY HASH(device_uid) BUCKETS 1
ORDER BY (device_uid, changed_at)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "365"
);
