## ADDED Requirements

### Requirement: Dedicated flows JetStream stream
The flow-collector SHALL publish raw flow protobufs to a dedicated JetStream stream whose default name is `flows` (configurable via `stream_name`). The stream SHALL include at least the subjects `flows.raw.netflow` and `flows.raw.sflow` when those listeners are configured, and MAY include additional configured concrete `flows.raw.<name>` extension subjects. The dedicated flows stream SHALL NOT be the shared multi-signal `events` stream used for logs, Falco, or OTEL. EventWriter persistence consumers SHALL use concrete `flows.raw.<name>` leaves only. Whole-token wildcards under the flow namespace (e.g. `flows.raw.>`, `flows.>`, `*.>`) SHALL NOT be treated as EventWriter consumer filters and SHALL be rejected by collector config validation.

#### Scenario: Retired attribution canary subjects are not stream routes
- **GIVEN** historical demo records or configuration mention
  `flow.host-slice.<agent_id>` or `flow.attributed.<partition>`
- **WHEN** flow-collector and EventWriter reconcile the dedicated flow stream
- **THEN** they SHALL NOT publish, rehome, subscribe to, or consume either
  retired namespace
- **AND** they SHALL NOT reserve either namespace for a future attribution join
- **AND** the current agent-up attribution and core-correlation contract SHALL
  remain owned by `harden-flow-attribution-pipeline`, not this flow-collector
  delta

#### Scenario: Default stream name is flows
- **WHEN** the collector starts without an explicit override that points at `events`
- **THEN** it SHALL use stream name `flows` for JetStream ensure/publish
- **AND** it SHALL publish netflow messages to subject `flows.raw.netflow`

#### Scenario: Shared events stream is not the flow target
- **WHEN** operators configure production defaults from the Helm chart
- **THEN** the flow-collector config SHALL target the dedicated flows stream
- **AND** raw NetFlow SHALL NOT depend on shared `events` retention limits for durability

### Requirement: Flow stream retention is collector-reconciled
The flow-collector SHALL ensure the flows JetStream stream exists with configured `max_bytes`, `max_age`, replica count, file storage, and discard-old limits policy. When the stream already exists, the collector SHALL reconcile subjects (union), `num_replicas`, `max_bytes`, and `max_age` to match its configuration—not only subjects and replicas.

#### Scenario: Create stream with retention bounds
- **WHEN** the flows stream does not exist at collector startup
- **THEN** the collector SHALL create it with configured `max_bytes`, `max_age`, and `num_replicas`
- **AND** storage SHALL be file-backed with discard-old behavior under limits retention

#### Scenario: Update existing stream retention
- **WHEN** the flows stream already exists with different `max_bytes` or `max_age` than the collector config
- **THEN** the collector SHALL update the stream configuration to the configured values
- **AND** it SHALL log the before/after retention settings at info level

#### Scenario: Configured concrete raw subject union is preserved
- **WHEN** the existing flows stream has subjects not listed in the current process config
- **THEN** the collector SHALL retain existing configured concrete
  `flows.raw.<name>` subjects while ensuring its required listener subjects are
  present
- **AND** it SHALL NOT treat `flow.host-slice.*` or `flow.attributed.*` as raw
  extension subjects or add either namespace while creating or transferring
  subject ownership
- **AND** any dormant pre-existing canary subject entry retained during safe
  subject-union migration SHALL have no publisher or consumer and SHALL NOT be
  treated as current or future routing

### Requirement: Flow stream config is not owned by log or OTEL collectors
Log-collector and OTEL JetStream ensure paths SHALL NOT create or update the dedicated flows stream or attach `flows.raw.*` subjects to the shared `events` stream as part of their ensure routine.

#### Scenario: OTEL restart does not shrink flow retention
- **WHEN** the OTEL or log collector reconnects to NATS and reconciles its stream
- **THEN** it SHALL leave the flows stream `max_bytes` and `max_age` unchanged
- **AND** it SHALL NOT move raw flow subjects onto `events`

### Requirement: Production and demo sizing defaults for flows
Helm defaults SHALL size the dedicated flows stream for multi-hour recovery lag headroom rather than a thrift 1 GiB shared bus. Production chart defaults SHALL use at least **10 GiB** `stream_max_bytes` and multi-hour `max_age` when JetStream file-store capacity allows, and SHALL size companion NATS reservations (maxFileStore, datasvc KV/object, events) so the R=3 placement fits the chart's PVC without claiming impossible budgets. Docker/tenant/image overlays MAY use smaller explicit overrides. Demo overlays MAY use smaller absolute values but MUST keep flows on the dedicated stream and MUST document the NATS `max_file_store` / PVC budget required for the chosen replica count. Collectors with `stream_name: events` SHALL NOT apply flow retention fields to reshape the shared multi-signal stream.

#### Scenario: Production chart targets dedicated capacity
- **WHEN** an operator installs with production chart defaults and flow-collector enabled
- **THEN** flow-collector config SHALL reference the dedicated flows stream
- **AND** `stream_max_bytes` SHALL be at least an order of magnitude above the historical 1 GiB demo shared cap unless an overlay explicitly overrides for a smaller file store
- **AND** the sum of bounded JetStream reservations at R=3 SHALL fit under `nats.jetstream.maxFileStore` on the chart's default PVC

#### Scenario: Demo no longer shares 1 GiB events budget for flows
- **WHEN** demo values enable the flow-collector
- **THEN** flow retention SHALL be configured on the dedicated flows stream
- **AND** the values comments SHALL describe the JetStream file-store budget implication of stream size × replicas

### Requirement: Downgrade restores subject ownership before an old image starts
Deployment tooling and operator documentation SHALL NOT claim that a plain Helm
rollback to a pre-migration flow-collector image is safe. Before an image without
reverse-transfer support starts with `stream_name: events`, the currently running
migration-capable image SHALL first transfer the configured concrete flow subjects
from `flows` back to `events` and pass its post-transfer readiness gate.

#### Scenario: Helm rollback targets a legacy events publisher
- **WHEN** an operator selects a Helm revision whose flow collector targets `events`
- **THEN** guarded pre-downgrade tooling SHALL run the current image in legacy events mode before invoking `helm rollback`
- **AND** it SHALL wait for ready-file success and reverse-transfer confirmation before allowing the old image to start
- **AND** it SHALL fail closed when the current Deployment still uses process-only readiness or a non-Recreate rollout strategy

#### Scenario: GitOps restores a legacy revision
- **WHEN** a GitOps controller will replace the current chart with a legacy revision
- **THEN** operators SHALL pause reconciliation and run the same pre-downgrade transfer in prepare-only mode using the target revision's rendered flow-collector config rather than Helm release history
- **AND** the runbook SHALL require the legacy revision to be applied immediately after preparation succeeds
