## MODIFIED Requirements
### Requirement: No KV-backed service configuration
ServiceRadar components MUST NOT depend on NATS KV (nats-kv) or any KV-backed configuration distribution mechanism for startup, runtime configuration, or secrets. Agents SHALL obtain dynamic configuration via gRPC from the control plane, and collectors SHALL read configuration from local filesystem files (JSON/YAML) or from agent-delivered config when embedded.

Zen and core-elx MAY use datasvc internally for rule synchronization, but operators MUST NOT be required to manage rules via direct KV manipulation as part of normal operation.

#### Scenario: Agent starts without KV access
- **GIVEN** an agent with no KV endpoint configured
- **WHEN** the agent starts and completes enrollment
- **THEN** it retrieves configuration via gRPC
- **AND** continues operating without a KV dependency

#### Scenario: Collector loads filesystem config
- **GIVEN** a collector with `config.json` on disk
- **WHEN** it starts
- **THEN** it loads configuration from the filesystem
- **AND** it does not attempt KV reads/watches

#### Scenario: Rules do not require manual KV operations
- **GIVEN** an operator updates normalization rules or alert rules in the UI/API
- **WHEN** the platform persists and distributes the update
- **THEN** zen receives updated rule state without requiring the operator to write KV keys directly
