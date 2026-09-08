# cnpg — spec deltas

## ADDED Requirements

### Requirement: Analytics query-head image is separate from the primary image
The project SHALL build and publish a dedicated analytics PostgreSQL image (`serviceradar-cnpg-analytics`): PostgreSQL 18 with pg_duckdb and its required C++ runtime libraries, and WITHOUT TimescaleDB, Apache AGE, or PostGIS. The primary CNPG image's extension set, shared_preload_libraries, and digest pins SHALL NOT change as part of the cold tier. Every analytics-image digest bump SHALL be gated by a boot-smoke CI test (instance start, `CREATE EXTENSION pg_duckdb`, a `read_parquet` round-trip).

#### Scenario: Primary image unaffected
- **WHEN** the cold tier is introduced or upgraded
- **THEN** the primary CNPG image and its pinned digests are unchanged and no primary instance restart is required

#### Scenario: Broken analytics image cannot ship
- **WHEN** an analytics-image build fails the boot-smoke test
- **THEN** the digest pin cannot be bumped and no deployment receives the image

### Requirement: Analytics query-head cluster is default-disabled with bounded resource posture
The Helm chart SHALL provide an analytics query-head component (a small single-instance CNPG cluster using the analytics image) that renders nothing by default. When enabled by deployment values, it SHALL apply a bounded DuckDB posture: execution gated to a dedicated role, per-connection memory and thread caps, spill directed to a dedicated ephemeral volume with a size cap, local filesystem access disabled, and community/auto-installed extensions disabled with required extensions pre-packaged. Its resource requests SHALL be derived from the configured connection pool size and per-connection memory cap.

#### Scenario: Default OSS install
- **WHEN** the chart is installed with default values
- **THEN** no analytics query-head resources are rendered

#### Scenario: Enabled with posture
- **WHEN** deployment values enable the analytics head
- **THEN** the rendered cluster carries the role gate, memory/thread caps, ephemeral spill volume with size cap, and filesystem/extension restrictions
