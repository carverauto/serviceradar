# advisory-feed-producers (delta)

This change supersedes the add-on-based advisory producer model proposed in
`complete-security-analytics-pipeline` (section D). Advisory feeds are acquired,
parsed, and loaded by **core-elx**, not by an agent add-on.

## ADDED Requirements

### Requirement: Core-scheduled advisory feed ingestion
Advisory vulnerability feeds (CISA KEV, VulnCheck KEV, VulnCheck nist-nvd2, NVD CVE 2.0) SHALL be acquired and ingested by core-elx on an AshOban schedule, with no dependency on any agent being online. The system SHALL NOT ship bulk feed payloads through the agent → agent-gateway pipeline.

#### Scenario: Scheduled refresh without an agent
- **GIVEN** the advisory feeds feature is enabled
- **WHEN** the AshOban trigger for a feed fires (default ~6h cadence; CISA KEV more frequent)
- **THEN** core-elx acquires and ingests the feed without dispatching any command to an agent
- **AND** no `producer_schedule_dispatch_failed` / `agent_offline` outcome is possible for feed refresh

#### Scenario: Operator-triggered run
- **GIVEN** a feed configured in the Vulnerability Intelligence settings
- **WHEN** an operator selects "Run now"
- **THEN** core-elx enqueues the feed's Oban job and reports last/next run, status, and record counts in the UI

### Requirement: Disk-staged feed acquisition
Feed acquisition SHALL stage downloaded archives on a persistent on-disk volume and parse them off disk in a streaming fashion. The system SHALL NOT hold a full feed archive or full decompressed feed in memory.

#### Scenario: Large dump stays bounded in memory
- **GIVEN** the VulnCheck nist-nvd2 dump (~355 MB zip of ~181 gzipped NVD-2.0 shards)
- **WHEN** core-elx ingests it
- **THEN** the archive is streamed to the staging directory, extracted, and parsed shard-by-shard
- **AND** the resident working set is bounded by a single shard, not the full dataset

#### Scenario: Missing volume fails closed
- **GIVEN** the advisory staging volume is not mounted
- **WHEN** a large-feed (nist-nvd2) refresh is attempted
- **THEN** core-elx logs the missing volume and skips that feed
- **AND** does not fall back to an in-memory download

### Requirement: VulnCheck two-step backup acquisition
For VulnCheck feeds, the system SHALL resolve the backup index before download: call `GET /v3/backup/<index>` with the Bearer API token, read the first `data[]` entry's presigned `url`, and stream that archive to disk. The presigned URL SHALL be requested without the Authorization header and used promptly (15-minute TTL); when an index `sha256` is present it SHALL be verified.

#### Scenario: KEV backup resolves to a single JSON
- **GIVEN** a valid VulnCheck token and `vulncheck-kev` index
- **WHEN** the worker runs
- **THEN** it downloads the presigned zip, extracts the single `vulncheck_known_exploited_vulnerabilities.json`, and parses it as a CISA-KEV-shaped array (with `cve` as a list)

#### Scenario: nist-nvd2 backup resolves to gzipped shards
- **GIVEN** a valid VulnCheck token and `nist-nvd2` index
- **WHEN** the worker runs
- **THEN** it downloads the presigned zip and parses each `nvdcve-2.0-NNN.json.gz` member as NVD 2.0, extracting CPE coordinates with version bounds

### Requirement: Hybrid advisory storage with indexed coordinates
Ingested advisories SHALL be persisted both as a flexible JSONB record (full upstream CVE object, GIN-indexed) and as normalized, indexed coordinate rows extracted at load time. Loading SHALL use batched bulk upserts, not one ORM create per advisory. Endpoint CPE matching SHALL query the normalized coordinate rows, not parse JSONB at match time.

#### Scenario: Coordinates are individually indexed
- **GIVEN** an NVD CVE with multiple CPE match criteria
- **WHEN** it is ingested
- **THEN** the full CVE is stored as JSONB and each CPE coordinate is stored as a row in `advisory_coordinates` with parsed CPE-2.3 components and version bounds
- **AND** the coordinate rows are reachable via component btree and trigram indexes

#### Scenario: Bulk load
- **GIVEN** a feed with hundreds of thousands of advisories
- **WHEN** it is ingested
- **THEN** advisories and coordinates are written in chunked bulk upserts
- **AND** a consistent generation is swapped in atomically so matching never reads a half-loaded feed

### Requirement: CPE version-range endpoint matching
The endpoint vulnerability matcher SHALL evaluate CPE 2.3 component matches with wildcard handling and SHALL apply NVD version-range predicates (`versionStartIncluding`, `versionStartExcluding`, `versionEndIncluding`, `versionEndExcluding`) against the installed package version. It SHALL NOT cap the advisory set at a fixed limit, and SHALL NOT flag a package for a CVE whose version range excludes the installed version.

#### Scenario: Version outside range is not matched
- **GIVEN** a CVE affecting product X `>= 1.0 < 2.0` and an installed X `2.5`
- **WHEN** matching runs
- **THEN** no `endpoint_vulnerability_matches` row is written for that CVE/package

#### Scenario: Version inside range is matched
- **GIVEN** a CVE affecting product X `>= 1.0 < 2.0` and an installed X `1.4`
- **WHEN** matching runs
- **THEN** a match row is written with the version evidence recorded

### Requirement: Retire the advisory producer add-on
The Go advisory-producer add-on and the agent-dispatched advisory `producer-schedule:v1` path SHALL be removed. Existing producer assignments/schedules for advisories SHALL be cleaned up by a data migration.

#### Scenario: No add-on remains
- **WHEN** the change is deployed
- **THEN** `serviceradar-advisory-producer` is not built or shipped
- **AND** the Vulnerability Intelligence UI no longer shows a per-agent assignment for feeds
