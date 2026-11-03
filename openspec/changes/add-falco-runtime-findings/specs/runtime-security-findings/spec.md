## ADDED Requirements

### Requirement: Falco occurrences fold into one runtime finding per entity and rule
The system SHALL maintain exactly one runtime security finding per `(subject entity, Falco rule)` and SHALL update that finding for every Falco occurrence that resolves to the same entity and rule, instead of creating a new record per occurrence.
A runtime finding is an OCSF Detection Finding (class 2004) stored in `platform.ocsf_findings` with a typed runtime extension row. It carries status, episode severity, first seen, last seen, lifetime occurrence count, episode occurrence count, reopen count, a fixed-window rate counter, bounded samples, and its inventory binding.

#### Scenario: A burst from one workload produces one finding
- **GIVEN** Falco reports 500 occurrences of rule `Terminal shell in container` from pods of Deployment `shop/cart` on three nodes
- **WHEN** EventWriter processes the occurrences
- **THEN** exactly one runtime finding SHALL exist for `k8s_workload default/shop/Deployment/cart` and that rule
- **AND** its occurrence count SHALL be 500 and its node samples SHALL list the three nodes with per-node counts

#### Scenario: A different rule on the same workload is a separate finding
- **GIVEN** an active finding for rule `Terminal shell in container` on Deployment `shop/cart`
- **WHEN** an occurrence of rule `Write below etc` arrives from the same Deployment
- **THEN** the system SHALL create a second finding for that rule
- **AND** the first finding's counts SHALL NOT change

### Requirement: Runtime finding subjects use the most specific stable entity
The normalizer SHALL select the subject entity of each Falco occurrence in this order: Kubernetes workload when namespace, owner kind and owner name are known; Kubernetes pod when namespace and pod name are known without an owner; host for `syscall` events without pod context; Falco source for non-`syscall` sources.
The normalizer MUST NOT infer a workload owner by parsing pod names. A container-only occurrence SHALL first be enriched from `platform.workload_identity_current` by partition and container id, and SHALL fall back to the host subject when no pod is found. Cluster identity SHALL come from the `serviceradar.cluster_id` field and default to `default` when absent.

#### Scenario: Owner fields present yield a workload subject
- **GIVEN** an occurrence with `k8s.ns.name = shop`, `k8s.pod.name = cart-7d9f8-abcde` and owner fields `Deployment` / `cart`
- **WHEN** it is normalized
- **THEN** its subject SHALL be `k8s_workload` with key `default/shop/Deployment/cart`
- **AND** `attribution_status` SHALL be `resolved`

#### Scenario: Pod without owner yields a pod subject without guessing
- **GIVEN** an occurrence with namespace `shop` and pod `cart-7d9f8-abcde` and no owner fields
- **WHEN** it is normalized
- **THEN** its subject SHALL be `k8s_pod` with key `default/shop/cart-7d9f8-abcde`
- **AND** `attribution_status` SHALL be `partial`
- **AND** the system SHALL NOT derive an owner named `cart` from the pod name

#### Scenario: Container-only occurrence is enriched from workload identity
- **GIVEN** an occurrence with container id `0123456789ab` and no Kubernetes fields
- **AND** `workload_identity_current` maps that container id in the same partition to pod `shop/cart-7d9f8-abcde`
- **WHEN** it is normalized
- **THEN** its subject SHALL be the pod or its workload
- **AND** `attribution_status` SHALL be `enriched`

#### Scenario: Container-only occurrence without workload identity falls back to the host
- **GIVEN** an occurrence from host `host01.example.com` with container id `0123456789ab`, image `registry.example.com/build/runner`, and no matching workload identity
- **WHEN** it is normalized
- **THEN** its subject SHALL be `host` with key `<partition>/host01.example.com`
- **AND** the container id and image SHALL be recorded on the occurrence and in the finding's samples

### Requirement: Runtime finding identity is stable across restarts and bindings
The finding uid SHALL be a deterministic function of the entity kind, the entity key built from observed coordinates, and the Falco rule name, and MUST NOT include container id, pod uid, device uid, or the ingest subject.

#### Scenario: Pod restart keeps the finding
- **GIVEN** an active workload finding whose occurrences came from container `aaaaaaaaaaaa`
- **WHEN** the pod restarts and the same rule fires from container `bbbbbbbbbbbb`
- **THEN** the occurrence SHALL update the existing finding

#### Scenario: Late device binding keeps the finding
- **GIVEN** an unbound host finding for `host01.example.com`
- **WHEN** a device for that host joins inventory and re-resolution binds it
- **THEN** the finding uid SHALL be unchanged and its `device_uid` SHALL be set

### Requirement: Inventory binding records its method and never guesses
The system SHALL bind each runtime finding's subject, and the node each occurrence ran on, to an inventory device and SHALL record the binding status (`bound`, `ambiguous`, `unbound`) and, when bound, the method (`explicit_uid`, `agent`, `workload_identity`, `k8s_node`, `hostname_unique`).
A hostname lookup that matches more than one non-deleted device MUST produce `ambiguous` with the candidate count and no device. A periodic, bounded re-resolution job SHALL retry findings that are unbound, ambiguous, or bound to a device that has since been deleted or merged, and a merged device SHALL be followed to its canonical device.

#### Scenario: Shared hostname is ambiguous
- **GIVEN** two non-deleted devices named `node01` in inventory
- **WHEN** a host occurrence from `node01` has no agent, workload or node match
- **THEN** the finding SHALL have `binding_status = ambiguous` with `binding_candidates = 2`
- **AND** it SHALL appear on neither device's page

#### Scenario: Agent binding wins over hostname
- **GIVEN** an occurrence whose node maps through `workload_identity_current` to agent `agent-host01`, bound to device `sr:00000000-0000-4000-8000-000000000001`
- **WHEN** it is resolved
- **THEN** `node_device_uid` SHALL be that device with method `workload_identity`

#### Scenario: Unresolvable host remains visible
- **GIVEN** a host occurrence from `host09.example.com` with no matching device
- **WHEN** it is processed
- **THEN** the finding SHALL be created with `binding_status = unbound`
- **AND** it SHALL be listed among unbound runtime findings

#### Scenario: Merged device binding follows the canonical device
- **GIVEN** a finding bound to a device that DIRE later merges into another device
- **WHEN** re-resolution runs
- **THEN** the finding SHALL be bound to the canonical device

### Requirement: Falco ingestion does not mutate inventory identity
Runtime finding binding MUST NOT create, merge, restore, or revive devices and MUST NOT contribute device identity facts.

#### Scenario: Unknown host creates no device
- **GIVEN** an occurrence from a host not present in inventory
- **WHEN** it is processed
- **THEN** no device row SHALL be created or restored

### Requirement: Runtime finding aggregation is atomic and bounded
The system SHALL aggregate each batch's occurrences per finding into one atomic update that adds to the lifetime and episode counts, moves first seen and last seen monotonically, raises episode severity monotonically, maintains a one-hour tumbling window count, and merges bounded samples.
Concurrent updates from multiple EventWriter replicas MUST NOT lose counts. Samples SHALL be capped at fixed sizes: 10 process names, 5 latest command lines, 10 images, 20 nodes, 5 users, and 5 latest occurrence ids.

#### Scenario: Concurrent replicas do not lose updates
- **GIVEN** two EventWriter replicas each process a batch of 50 occurrences for the same finding at the same time
- **WHEN** both commit
- **THEN** the finding's occurrence count SHALL have increased by 100

#### Scenario: Samples stay bounded under high cardinality
- **GIVEN** a finding receives occurrences from 300 distinct command lines
- **WHEN** they are aggregated
- **THEN** the finding SHALL store at most 5 command lines

#### Scenario: Window rolls over
- **GIVEN** a finding whose window started at 10:00 with 40 occurrences
- **WHEN** an occurrence arrives at 11:05
- **THEN** a new window SHALL start and its count SHALL be 1

### Requirement: Runtime finding lifecycle
A runtime finding SHALL be `active`, `suppressed`, or `resolved`. It SHALL auto-resolve after a configurable quiet period without occurrences (default 24 hours), SHALL reopen on a new occurrence after resolution with a new episode, and SHALL support operator resolve and operator suppression with an optional expiry and reason.
A suppressed finding SHALL continue to count and sample occurrences and SHALL NOT emit alerting transitions.

#### Scenario: Quiet finding auto-resolves
- **GIVEN** an active finding with no occurrences for 24 hours
- **WHEN** the auto-resolve job runs
- **THEN** the finding SHALL become `resolved` and a `resolved` transition SHALL be emitted

#### Scenario: Resolved finding reopens
- **GIVEN** a resolved finding
- **WHEN** a new occurrence arrives
- **THEN** the finding SHALL become `active`, its reopen count SHALL increase by one, its episode counters SHALL restart, and a `reopened` transition SHALL be emitted

#### Scenario: Suppressed finding emits no alerting transition
- **GIVEN** a finding suppressed until tomorrow
- **WHEN** occurrences with a higher priority arrive
- **THEN** counts and samples SHALL update
- **AND** no `escalated` transition SHALL be emitted

### Requirement: Runtime occurrences are telemetry on exactly one backend
The system SHALL store every Falco occurrence in the `runtime_security_occurrences` dataset with typed columns for the rule, priority, entity, binding, Kubernetes, container, process, user, file, network, and MITRE fields. With StarRocks enabled it SHALL write and read the warehouse only. With StarRocks disabled it SHALL write and read CNPG.
The system MUST NOT write occurrences to both backends and MUST keep the CNPG table, writer and reader for installations without StarRocks. The occurrence id SHALL be derived from the Falco `uuid` when present and otherwise from the raw bytes, identically on the direct and log-promotion paths. Falco occurrences SHALL NOT be written to `ocsf_events`, and the direct Falco processor SHALL NOT write a per-occurrence `logs` row.

#### Scenario: StarRocks enabled
- **GIVEN** StarRocks is enabled
- **WHEN** a Falco batch is processed
- **THEN** its occurrences SHALL be loaded into the warehouse
- **AND** no CNPG occurrence row SHALL be written

#### Scenario: StarRocks disabled
- **GIVEN** StarRocks is disabled
- **WHEN** a Falco batch is processed
- **THEN** its occurrences SHALL be written to the CNPG occurrence table

#### Scenario: Same record on both paths is one occurrence
- **GIVEN** a Falco record with `uuid` `11111111-1111-4111-8111-111111111111` arrives on the direct path and is also promoted from the log path
- **WHEN** both are processed
- **THEN** one occurrence SHALL exist and the finding SHALL count it once

#### Scenario: Occurrence load failure updates no finding
- **GIVEN** the occurrence load for a batch fails
- **WHEN** the batch is processed
- **THEN** no finding SHALL be updated for that batch
- **AND** the batch SHALL NOT be acknowledged

### Requirement: Raw Falco evidence is retained byte-exact
Each occurrence SHALL retain its raw Falco record byte-exact with its SHA-256 digest and byte length, and the system MUST NOT truncate raw evidence on either backend.
A record larger than the backend's evidence column SHALL be stored with no raw payload, its digest and length, and `evidence_status = oversize`, and SHALL be counted in telemetry and raised as a health event.

#### Scenario: Raw evidence round-trips
- **GIVEN** a Falco record whose `output` is 80,000 bytes
- **WHEN** it is stored and read back through `in:runtime_security_occurrences`
- **THEN** the returned raw payload SHALL equal the received bytes and match the stored digest

#### Scenario: Oversize record is not cut
- **GIVEN** a log-path Falco record larger than 1,048,576 bytes on a StarRocks installation
- **WHEN** it is stored
- **THEN** the occurrence SHALL carry `evidence_status = oversize`, the digest and the length
- **AND** no truncated payload SHALL be stored

### Requirement: Runtime finding retention
The system SHALL keep active and suppressed findings, SHALL delete resolved findings a configurable period after resolution (default 90 days) with a bounded prune job, and SHALL age occurrences out on the occurrence dataset's telemetry retention.
Deleting a finding MUST NOT delete its occurrences, and a finding's samples SHALL remain readable after its occurrences have expired.

#### Scenario: Resolved finding is pruned
- **GIVEN** a finding resolved 91 days ago
- **WHEN** the prune job runs
- **THEN** the finding and its runtime extension row SHALL be deleted

### Requirement: Falcosidekick bundles stamp cluster and partition
Generated Falcosidekick collector bundles SHALL configure the custom fields `serviceradar.cluster_id` and `serviceradar.partition`, and occurrences without them SHALL use cluster `default` and the package's partition.

#### Scenario: Existing bundle without custom fields
- **GIVEN** a Falcosidekick package generated before this change
- **WHEN** its events are processed
- **THEN** findings SHALL be keyed under cluster `default`

### Requirement: Falco ingestion stays on JetStream with a transport-independent normalizer
Falco ingestion SHALL remain on the existing NATS JetStream `falco.>` path, and the normalizer SHALL accept a decoded Falco record with ingest metadata so that a future edge-record contract projector can call it unchanged.

#### Scenario: Normalizer input is independent of transport
- **WHEN** the direct processor and the log-promotion path normalize the same Falco record
- **THEN** both SHALL call the same normalizer and produce identical occurrence and finding deltas apart from `ingest_path`
