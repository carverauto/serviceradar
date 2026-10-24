-- Current state is unpartitioned: terminal facts are permanent sequence watermarks.
CREATE TABLE IF NOT EXISTS serviceradar.exposure_facts (
  device_ord BIGINT NOT NULL,
  cve_ord BIGINT NOT NULL,
  pkg_ord BIGINT NOT NULL,
  pkgver_ord BIGINT NOT NULL,
  state TINYINT NOT NULL,
  source_scope VARCHAR(32),
  severity_rank TINYINT,
  cvss_score DECIMAL(3,1),
  kev BOOLEAN,
  exploit_available BOOLEAN,
  fix_available BOOLEAN,
  first_exposed_at DATETIME,
  resolved_at DATETIME,
  updated_at DATETIME NOT NULL,
  transition_seq BIGINT NOT NULL,
  transition_xid BIGINT NOT NULL,
  snapshot_generation BIGINT NOT NULL DEFAULT "0"
)
PRIMARY KEY (device_ord, cve_ord, pkg_ord)
DISTRIBUTED BY HASH(device_ord) BUCKETS 16
ORDER BY (cve_ord, device_ord)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true"
);

CREATE TABLE IF NOT EXISTS serviceradar.exposure_cve_dim (
  cve_ord BIGINT NOT NULL,
  cve_id VARCHAR(512) NOT NULL,
  epss_score DOUBLE,
  updated_at DATETIME NOT NULL
)
PRIMARY KEY (cve_ord)
DISTRIBUTED BY HASH(cve_ord) BUCKETS 4
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true"
);

-- Package versions coexist across devices; identity alone cannot key this dimension.
CREATE TABLE IF NOT EXISTS serviceradar.exposure_package_dim (
  pkgver_ord BIGINT NOT NULL,
  pkg_ord BIGINT NOT NULL,
  package_identity_key STRING NOT NULL,
  package_name STRING NOT NULL,
  installed_version STRING NOT NULL,
  updated_at DATETIME NOT NULL
)
PRIMARY KEY (pkgver_ord)
DISTRIBUTED BY HASH(pkgver_ord) BUCKETS 8
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true"
);

-- History may expire; unlike the fact table it is append-only and daily partitioned.
-- payload retains the complete transition, including reasons and changed fields.
CREATE TABLE IF NOT EXISTS serviceradar.exposure_transitions_log (
  changed_at DATETIME NOT NULL,
  device_ord BIGINT NOT NULL,
  cve_ord BIGINT NOT NULL,
  pkg_ord BIGINT NOT NULL,
  transition_seq BIGINT NOT NULL,
  transition_xid BIGINT NOT NULL,
  pkgver_ord BIGINT NOT NULL,
  state TINYINT NOT NULL,
  first_exposed_at DATETIME,
  resolved_at DATETIME,
  payload JSON NOT NULL
)
DUPLICATE KEY (changed_at, device_ord, cve_ord, pkg_ord)
PARTITION BY date_trunc('day', changed_at)
DISTRIBUTED BY HASH(device_ord) BUCKETS 16
PROPERTIES (
  "replication_num" = "3",
  "partition_live_number" = "365"
);
