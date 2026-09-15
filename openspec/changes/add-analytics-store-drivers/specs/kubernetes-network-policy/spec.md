## ADDED Requirements

### Requirement: Analytics-head network access is least-privilege and storage-aware
When the pg_duckdb driver is enabled, the chart SHALL render NetworkPolicies granting the analytics head ingress from core and web on the PostgreSQL port. Egress to object storage SHALL be rendered only for the S3 backend. The filesystem backend SHALL NOT open object-store egress. When the driver is `timescale`, no analytics-head NetworkPolicies SHALL be rendered.

#### Scenario: S3 backend
- **WHEN** `analyticsStore.driver` is `pg_duckdb` and storage is `s3`
- **THEN** NetworkPolicies allow core/web ingress to the head and head egress to the configured object-store endpoint

#### Scenario: Filesystem backend
- **WHEN** `analyticsStore.driver` is `pg_duckdb` and storage is `filesystem`
- **THEN** NetworkPolicies allow core/web ingress to the head
- **AND** they do not grant object-store egress

#### Scenario: Timescale driver
- **WHEN** `analyticsStore.driver` is `timescale`
- **THEN** no analytics-head NetworkPolicies are rendered
