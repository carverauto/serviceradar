## ADDED Requirements
### Requirement: SPIFFE identity errors are actionable for Zen
When the zen consumer runs with SPIFFE-enabled gRPC, it SHALL treat SPIFFE Workload API "no identity issued" responses as configuration errors, log actionable guidance, retry for a bounded interval, and then exit with a clear error.

#### Scenario: Missing SPIFFE registration for zen
- **GIVEN** zen is configured to use SPIFFE for gRPC
- **AND** the SPIFFE Workload API returns PermissionDenied with "no identity issued"
- **WHEN** zen attempts to load its X.509 SVID
- **THEN** zen logs that SPIFFE registration is missing or mismatched and includes the trust domain
- **AND** zen retries for a bounded interval before exiting with an error
