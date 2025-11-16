## MODIFIED Requirements
### Requirement: Postgres-native unified device and registry tables
ServiceRadar MUST maintain canonical device inventory, poller/agent/checker registries, and the associated materialized state in ordinary Postgres tables with row-level version metadata instead of relying on Proton’s immutable streams.

#### Scenario: Registry queries keep working
- **GIVEN** a CLI or API request hits `pkg/registry.ServiceRegistry.GetPoller`/`ListPollers`
- **WHEN** the request executes
- **THEN** it reads from the Postgres tables (`pollers`, `agents`, `checkers`, `service_status` history) and returns the same shape/results that the Proton-backed queries produced.

#### Scenario: Registry uses native pgx helpers
- **GIVEN** any registry read/write (`DeleteService`, `PurgeInactive`, registration events, etc.)
- **WHEN** it touches the database
- **THEN** the code calls the shared CNPG helpers (or pgx APIs) directly with `$n` placeholders—no Proton-style `?` rewriting, compatibility shims, or `PrepareBatch` emulation remain in `pkg/db`.
