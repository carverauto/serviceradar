## ADDED Requirements
### Requirement: Docker Compose seeds NetFlow Zen rules when enabled
The Docker Compose stack SHALL run a NetFlow rule seeding step when NetFlow ingestion is enabled so Zen can process
NetFlow records immediately after startup, retrying on transient KV failures.

#### Scenario: NetFlow-enabled compose boot
- **GIVEN** the compose stack enables the NetFlow collector
- **WHEN** the stack starts
- **THEN** a `zen-put-rule` step SHALL seed the NetFlow rule bundle into KV
- **AND** transient KV failures SHALL trigger retries before reporting failure
- **AND** the NetFlow rule seeding step SHALL complete before NetFlow traffic is processed
