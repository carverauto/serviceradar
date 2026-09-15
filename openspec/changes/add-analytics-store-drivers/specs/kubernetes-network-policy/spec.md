## ADDED Requirements

### Requirement: Analytics-head network access is least-privilege and storage-aware
When an analytics head is explicitly enabled for hybrid, pg_duckdb, named dual writes, or idle preparation, the chart SHALL render NetworkPolicies granting the analytics head ingress from core and web on the PostgreSQL port. Egress to object storage SHALL be rendered only for the S3 backend. The filesystem backend SHALL NOT open object-store egress. The default Timescale-only installation SHALL NOT render analytics-head NetworkPolicies.

#### Scenario: S3 backend
- **WHEN** `analyticsStore.driver` is `pg_duckdb` or `hybrid` and storage is `s3`
- **THEN** NetworkPolicies allow core/web ingress to the head and head egress to the configured object-store endpoint

#### Scenario: Filesystem backend
- **WHEN** `analyticsStore.driver` is `pg_duckdb` or `hybrid` and storage is `filesystem`
- **THEN** NetworkPolicies allow core/web ingress to the head
- **AND** they do not grant object-store egress

#### Scenario: Timescale driver
- **WHEN** `analyticsStore.driver` is `timescale` and no head or archive writes are enabled
- **THEN** no analytics-head NetworkPolicies are rendered
