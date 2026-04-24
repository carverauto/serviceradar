# observability-netflow Specification

## Purpose
TBD - created by archiving change add-netflow-geoip-refresh. Update Purpose after archive.
## Requirements
### Requirement: GeoIP provider settings
The system SHALL provide an admin-configurable GeoIP enrichment provider for NetFlow enrichment and geo visualizations.

Supported providers SHALL include:
- Local MMDB (GeoLite-derived) as the default provider
- Optional hosted provider mode (ipinfo-lite)

#### Scenario: Admin selects provider and enables enrichment
- **GIVEN** an authenticated user with `admin` role
- **WHEN** the user selects the GeoIP provider and enables GeoIP enrichment
- **THEN** the system persists the provider configuration
- **AND** subsequent enrichment jobs use the configured provider

### Requirement: GeoIP provider credentials are encrypted at rest
When a GeoIP provider requires an API token (for example ipinfo-lite), the system SHALL store the token encrypted at rest using AshCloak and SHALL NOT persist plaintext tokens.

#### Scenario: Admin saves an API token
- **GIVEN** an authenticated user with `admin` role
- **WHEN** the user saves a provider API token
- **THEN** the system stores the token encrypted at rest
- **AND** the token is not returned in plaintext to non-admin users

### Requirement: Scheduled GeoIP dataset refresh (MMDB)
When using the local MMDB provider, the system SHALL refresh GeoIP datasets on a schedule (default daily) using a background job.

#### Scenario: Daily refresh runs and swaps MMDB atomically
- **GIVEN** GeoIP enrichment is enabled with the MMDB provider
- **WHEN** the scheduled refresh job runs
- **THEN** the system downloads the new MMDB dataset(s)
- **AND** swaps the dataset files atomically
- **AND** records refresh status and timestamp

### Requirement: GeoIP cache population from observed NetFlow IPs
The system SHALL populate `platform.ip_geo_enrichment_cache` via background jobs using IPs observed in NetFlow flows, so SRQL queries can join against cached enrichment data.

#### Scenario: Newly-seen flow IP is enriched
- **GIVEN** NetFlow flows contain an IP that is not present in `platform.ip_geo_enrichment_cache`
- **WHEN** the cache population job runs
- **THEN** the system enriches the IP via the configured provider
- **AND** upserts a cache row for that IP

### Requirement: Admin settings UI and RBAC
The system SHALL provide an admin settings UI for GeoIP enrichment configuration and SHALL restrict access to admin users.

#### Scenario: Non-admin attempts to access GeoIP settings
- **GIVEN** an authenticated user with role `viewer` (or `operator`)
- **WHEN** the user navigates to the GeoIP settings UI
- **THEN** the system denies access
