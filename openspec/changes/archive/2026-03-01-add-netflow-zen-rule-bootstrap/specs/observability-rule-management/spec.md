## ADDED Requirements
### Requirement: NetFlow Zen rule bootstrap via deployment tooling
When NetFlow ingestion is enabled, deployment tooling SHALL load the NetFlow Zen rule bundle into datasvc KV using
`zen-put-rule` (or equivalent) so Zen can transform NetFlow records without manual intervention, retrying on
transient datasvc/NATS errors.

#### Scenario: Helm install with NetFlow enabled
- **GIVEN** the Helm values enable the NetFlow collector
- **WHEN** the Helm release is installed or upgraded
- **THEN** the NetFlow rule bundle SHALL be written to KV for the platform tenant
- **AND** the operation SHALL be idempotent when re-run
- **AND** transient KV failures SHALL trigger retries before reporting failure

#### Scenario: Static Kubernetes manifest install
- **GIVEN** the static Kubernetes manifests enable the NetFlow collector
- **WHEN** the manifests are applied
- **THEN** the NetFlow rule bundle SHALL be written to KV via `zen-put-rule`
- **AND** transient KV failures SHALL trigger retries before reporting failure
- **AND** failures after retries SHALL be surfaced in the deployment status

#### Scenario: Docker Compose NetFlow bootstrap
- **GIVEN** the Docker Compose stack enables the NetFlow collector
- **WHEN** the stack starts
- **THEN** the NetFlow rule bundle SHALL be written to KV via `zen-put-rule`
- **AND** transient KV failures SHALL trigger retries before reporting failure
- **AND** the stack SHALL surface failures if rule seeding fails after retries
