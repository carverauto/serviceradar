## ADDED Requirements

### Requirement: Falco occurrences fold into one runtime finding per entity and rule
The system SHALL maintain exactly one runtime security finding per `(subject entity, Falco rule)` and SHALL update that finding for every Falco occurrence that resolves to the same entity and rule, instead of creating a new record per occurrence.
A runtime finding is an OCSF Detection Finding (class 2004) stored in `platform.ocsf_findings` with a typed runtime extension row. It carries status, episode severity, first seen, last seen, lifetime occurrence count, episode occurrence count, reopen count, bounded samples, and its inventory binding.

#### Scenario: A burst from one workload produces one finding
- **GIVEN** Falco reports 500 occurrences of rule `Terminal shell in container` from pods of Deployment `shop/cart` on three nodes, attested to partition `edge-a` with cluster id `default`
- **WHEN** EventWriter processes the occurrences
- **THEN** exactly one runtime finding SHALL exist for `k8s_workload edge-a/default/shop/Deployment/cart` and that rule
- **AND** its occurrence count SHALL be 500 and its node samples SHALL list the three nodes with per-node counts

#### Scenario: The same workload in two partitions is two findings
- **GIVEN** partition `edge-a` and partition `edge-b` each report rule `Terminal shell in container` for Deployment `shop/cart` with cluster id `default`
- **WHEN** both are normalized
- **THEN** two findings SHALL exist, with keys `edge-a/default/shop/Deployment/cart` and `edge-b/default/shop/Deployment/cart`
- **AND** their counts, samples, and device bindings SHALL NOT mix

#### Scenario: A different rule on the same workload is a separate finding
- **GIVEN** an active finding for rule `Terminal shell in container` on Deployment `shop/cart`
- **WHEN** an occurrence of rule `Write below etc` arrives from the same Deployment
- **THEN** the system SHALL create a second finding for that rule
- **AND** the first finding's counts SHALL NOT change

### Requirement: Runtime finding subjects use the most specific stable entity
The normalizer SHALL select the subject entity of each Falco occurrence in this order: Kubernetes workload when namespace, owner kind and owner name are known; Kubernetes pod when namespace and pod name are known without an owner; host for `syscall` events without pod context; Falco source for non-`syscall` sources.
The normalizer MUST NOT infer a workload owner by parsing pod names. A container-only occurrence SHALL first be enriched from `platform.workload_identity_current` by partition and container id, and SHALL fall back to the host subject when no pod is found. The partition SHALL be the attested partition of the edge record. The cluster id SHALL be the cluster id the agent stamped from `falcoIngest.clusterId`, defaulting to `default` when that value is absent. Workload and pod entity keys SHALL include the attested partition and the cluster id, in that order, so the same workload in two partitions is two findings.

#### Scenario: Owner fields present yield a workload subject
- **GIVEN** an occurrence attested to partition `edge-a` with cluster id `default`, `k8s.ns.name = shop`, `k8s.pod.name = cart-7d9f8-abcde`, and owner fields `Deployment` / `cart`
- **WHEN** it is normalized
- **THEN** its subject SHALL be `k8s_workload` with key `edge-a/default/shop/Deployment/cart`
- **AND** `attribution_status` SHALL be `resolved`

#### Scenario: Pod without owner yields a pod subject without guessing
- **GIVEN** an occurrence attested to partition `edge-a` with cluster id `default`, namespace `shop`, and pod `cart-7d9f8-abcde`, and no owner fields
- **WHEN** it is normalized
- **THEN** its subject SHALL be `k8s_pod` with key `edge-a/default/shop/cart-7d9f8-abcde`
- **AND** `attribution_status` SHALL be `partial`
- **AND** the system SHALL NOT derive an owner named `cart` from the pod name

#### Scenario: Container-only occurrence is enriched from workload identity
- **GIVEN** an occurrence with container id `0123456789ab` and no Kubernetes fields
- **AND** `workload_identity_current` maps that container id in the same partition to pod `shop/cart-7d9f8-abcde`
- **WHEN** it is normalized
- **THEN** its subject SHALL be the pod or its workload
- **AND** `attribution_status` SHALL be `enriched`

#### Scenario: Container-only occurrence without workload identity falls back to the host
- **GIVEN** an occurrence attested to partition `edge-a` from host `host01.example.com` with container id `0123456789ab`, image `registry.example.com/build/runner`, and no matching workload identity
- **WHEN** it is normalized
- **THEN** its subject SHALL be `host` with key `edge-a/host01.example.com`
- **AND** the container id and image SHALL be recorded on the occurrence and in the finding's samples

### Requirement: Runtime finding identity is stable across restarts and bindings
The finding uid SHALL be a deterministic function of the attested partition, the entity kind, the entity key, and the Falco rule name. The workload and pod entity keys SHALL begin with that same attested partition. The uid MUST NOT include container id, pod uid, device uid, or the ingest subject.

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

#### Scenario: Ambiguous subject remains visible on the bound node
- **GIVEN** a workload occurrence whose subject hostname matches two devices and whose node resolves through `k8s_node` to device `sr:00000000-0000-4000-8000-000000000001`
- **WHEN** it is resolved
- **THEN** the finding SHALL have `binding_status = ambiguous` and no subject `device_uid`
- **AND** `node_device_uid` SHALL be that device
- **AND** the finding SHALL be listed on that device's Runtime security tab

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
The system SHALL aggregate each batch's occurrences per finding into one atomic update that adds to the lifetime and episode counts, moves first seen and last seen monotonically, raises episode severity monotonically within the current episode, and merges bounded samples. The hourly timeline is a query over `runtime_security_occurrences`. The system SHALL NOT store a tumbling window counter.
Concurrent updates from multiple EventWriter replicas MUST NOT lose counts. Samples SHALL be capped at fixed sizes: 10 process names, 5 latest command lines, 10 images, 20 nodes, 5 users, and 5 latest occurrence ids.

#### Scenario: Concurrent replicas do not lose updates
- **GIVEN** two EventWriter replicas each process a batch of 50 occurrences for the same finding at the same time
- **WHEN** both commit
- **THEN** the finding's occurrence count SHALL have increased by 100

#### Scenario: Samples stay bounded under high cardinality
- **GIVEN** a finding receives occurrences from 300 distinct command lines
- **WHEN** they are aggregated
- **THEN** the finding SHALL store at most 5 command lines

### Requirement: Runtime finding lifecycle
A runtime finding SHALL be `active` or `resolved`. `active` is OCSF `status_id` 1 (New) or 2 (In Progress), and `resolved` is OCSF `status_id` 4 (Resolved). Falco SHALL store `status_id` 1 when it opens or reopens a finding and `status_id` 4 when it resolves one. Falco SHALL NOT store `status_id` 2 or 3. It SHALL auto-resolve after a configurable quiet period without occurrences (default 24 hours), SHALL reopen on a new occurrence after resolution with a new episode, and SHALL support operator resolve.
On reopen the new episode's severity SHALL start at the reopening occurrence's severity and SHALL then rise monotonically within that episode. The `reopened` transition SHALL carry that starting severity.
A new occurrence on an active finding SHALL update counts and samples, and SHALL emit `escalated` when the episode severity rises.

#### Scenario: Active and resolved use the OCSF status codes
- **GIVEN** a finding opens
- **THEN** its `status_id` SHALL be 1
- **WHEN** that finding resolves
- **THEN** its `status_id` SHALL be 4
- **AND** the finding SHALL NOT have been stored with `status_id` 2 or 3

#### Scenario: Quiet finding auto-resolves
- **GIVEN** an active finding with no occurrences for 24 hours
- **WHEN** the auto-resolve job runs
- **THEN** the finding SHALL become `resolved` with `status_id` 4 and a `resolved` transition SHALL be emitted

#### Scenario: Resolved finding reopens at the new occurrence's severity
- **GIVEN** a resolved finding whose previous episode severity was Critical
- **WHEN** a Warning occurrence arrives
- **THEN** the finding SHALL become `active`, its reopen count SHALL increase by one, and its episode counters SHALL restart
- **AND** the new episode severity SHALL be Warning
- **AND** the `reopened` transition SHALL carry Warning

#### Scenario: Later occurrence in the new episode can escalate
- **GIVEN** a finding reopened at Warning
- **WHEN** a Critical occurrence arrives in that episode
- **THEN** the episode severity SHALL become Critical
- **AND** an `escalated` transition SHALL be emitted

#### Scenario: Higher priority on an active finding escalates
- **GIVEN** an active finding
- **WHEN** an occurrence with a higher priority arrives
- **THEN** counts and samples SHALL update
- **AND** an `escalated` transition SHALL be emitted


### Requirement: Runtime occurrences are telemetry on exactly one backend
The system SHALL store every Falco occurrence in the `runtime_security_occurrences` dataset with typed columns for the rule, priority, entity, binding, relaying agent, Kubernetes, container, process, user, file, network, and MITRE fields. With StarRocks enabled it SHALL write and read the warehouse only. With StarRocks disabled it SHALL write and read CNPG.
The system MUST NOT write occurrences to both backends and MUST keep the CNPG table, writer and reader for installations without StarRocks. The occurrence id SHALL be derived from the Falco `uuid` when present and otherwise from the digest of the raw record. Recognized Falco records MUST NOT be written to `ocsf_events` as occurrences or to `logs` as generic log rows. Typed free-text columns MUST NOT be truncated.

#### Scenario: StarRocks enabled
- **GIVEN** StarRocks is enabled
- **WHEN** an accepted Falco batch is processed
- **THEN** its occurrences SHALL be loaded into the warehouse
- **AND** no CNPG occurrence row SHALL be written

#### Scenario: StarRocks disabled
- **GIVEN** StarRocks is disabled
- **WHEN** an accepted Falco batch is processed
- **THEN** its occurrences SHALL be written to the CNPG occurrence table

#### Scenario: No generic log row for a Falco record
- **WHEN** a recognized Falco record is processed
- **THEN** no `logs` row SHALL be written for it
- **AND** the record SHALL be queryable through `in:runtime_security_occurrences`

#### Scenario: Redelivered record is one occurrence
- **GIVEN** a Falco JSON event with `uuid` `11111111-1111-4111-8111-111111111111` is redelivered after a failed batch
- **WHEN** it is processed again
- **THEN** one occurrence SHALL exist

#### Scenario: Occurrence load failure updates no finding
- **GIVEN** the occurrence load for a batch fails
- **WHEN** the batch is processed
- **THEN** no finding SHALL be updated for that batch
- **AND** the stage SHALL be retained

### Requirement: Finding counts are at-least-once
Runtime finding occurrence counts SHALL be at-least-once. A count MAY exceed the stored occurrences only when a process stops between the finding commit and the acknowledgement of that write. A later publish of an occurrence whose finding update has already committed SHALL NOT apply the count delta again. The occurrence dataset SHALL remain the exact count.

#### Scenario: Exact count is available
- **WHEN** an operator needs the exact number of occurrences for a finding
- **THEN** a count over `in:runtime_security_occurrences` for that `finding_uid` SHALL provide it

#### Scenario: A retried publish does not count twice
- **GIVEN** an occurrence and its finding update are both committed
- **WHEN** the same Falco event is published again
- **THEN** the finding count SHALL NOT increase
- **AND** no second occurrence SHALL be written

### Requirement: Raw Falco evidence is lossless and never dropped
Each occurrence SHALL retain its raw Falco record losslessly with its SHA-256 digest and byte length. A record up to 1,048,576 bytes SHALL be stored inline on either backend; a larger record SHALL be uploaded to the datasvc object store before its occurrence is written, and the occurrence SHALL carry a reference `{store, key, sha256, bytes, content_type}` with key `runtime-security/raw/<UTC date of the occurrence>/<occurrence id>.json`.
The system MUST NOT truncate, drop, or merely flag raw evidence. A failed upload, including a full object store bucket, SHALL fail the batch so JetStream redelivers it, and SHALL be counted and raised as a health event. An incomplete part set still inside its reassembly window SHALL be acknowledged once each part is durably staged, SHALL NOT consume further delivery attempts, and SHALL NOT be dead-lettered. Falco SHALL NOT define its own dead-letter subject. A reassembled event whose occurrence or finding write keeps failing, before that delivery would reach `max_deliver`, SHALL be published as the original edge record to the generic edge-record dead-letter owned by the EventWriter edge-record processor (`feat/edge-record-dead-letter`). That publication SHALL be durable before the source is acknowledged. The retention pass SHALL treat the dead-lettered object reference as still referenced.

#### Scenario: Inline evidence round-trips
- **GIVEN** a Falco JSON event of 80,000 bytes
- **WHEN** it is stored and read back
- **THEN** the returned raw payload SHALL equal the posted JSON bytes and match the stored digest

#### Scenario: Large evidence goes out-of-line
- **GIVEN** a Falco record of 1,500,000 bytes
- **WHEN** it is stored
- **THEN** the object store SHALL hold the full bytes under the referenced key
- **AND** the occurrence SHALL carry the reference and no inline payload
- **AND** reading the object SHALL return bytes matching the referenced digest

#### Scenario: Object store refuses the upload
- **GIVEN** the object store bucket is full
- **WHEN** a batch needs to spill a record
- **THEN** the batch SHALL fail and the stage SHALL be retained
- **AND** no occurrence row SHALL be written without its evidence

#### Scenario: A failed occurrence write is dead-lettered before max delivery
- **GIVEN** a spilled object was uploaded and the occurrence write keeps failing
- **WHEN** the delivery would reach `max_deliver`
- **THEN** the original edge record SHALL be published durably to the generic edge-record dead-letter
- **AND** the source SHALL be acknowledged only after that publication is durable
- **AND** the object SHALL remain because the retention pass treats the dead-lettered reference as referenced

### Requirement: Spilled evidence retention follows its occurrence
A spilled raw evidence object SHALL be deleted only after the occurrence partition (warehouse) or chunk (CNPG) for its UTC day has been dropped on the active backend, plus a one-day grace, by the object store retention worker.
The retention worker MUST NOT delete an object whose day is still retained, and MUST NOT delete an object that a dead-lettered edge record still references.

#### Scenario: Retained day keeps its objects
- **GIVEN** occurrences for a day are still within telemetry retention
- **WHEN** the object store retention worker runs
- **THEN** no evidence object under that day's prefix SHALL be deleted

#### Scenario: Expired day is cleaned
- **GIVEN** a day's occurrence partition was dropped two days ago
- **AND** one object under that prefix is still referenced by a dead-lettered edge record
- **WHEN** the object store retention worker runs
- **THEN** the other evidence objects under that day's prefix SHALL be deleted
- **AND** the dead-lettered object SHALL remain

### Requirement: Runtime finding retention
The system SHALL keep active findings, SHALL delete resolved findings a configurable period after resolution (default 90 days) with a bounded prune job, and SHALL age occurrences out on the occurrence dataset's telemetry retention.
Deleting a finding MUST NOT delete its occurrences, and a finding's samples SHALL remain readable after its occurrences have expired.

#### Scenario: Resolved finding is pruned
- **GIVEN** a finding resolved 91 days ago
- **WHEN** the prune job runs
- **THEN** the finding and its runtime extension row SHALL be deleted

### Requirement: Falco events reach the agent over http_output
Falco events SHALL reach ServiceRadar only as JSON posted by Falco's native `http_output` to the agent's HTTPS endpoint `POST /v1/falco/events`. Falcosidekick SHALL NOT be on this path, and the agent SHALL be the only component that sends the events on to ServiceRadar.
The endpoint SHALL require mTLS with the chart-issued client certificate, the same caller authentication the agent already uses. It SHALL NOT accept a bearer token and SHALL NOT bind to loopback only: the Falco DaemonSet posts to the agent Service, and Falco's `http_output` has client-certificate settings and no custom-header token. The agent SHALL accept one JSON object per request with `compress_uploads` off, and the stored raw record SHALL be those JSON bytes.
The agent SHALL return success only after every part of that event is in its durable edge spool. A body that is not one JSON object, or a spool admission that fails, SHALL get a non-success response and SHALL NOT be acknowledged as stored. The release that introduces this path SHALL remove the NATS `falco.*` consumer, processor, subject permissions, Falcosidekick NATS identity, and collector-package NATS credentials, and SHALL NOT offer a setting that keeps both paths. A Falco-shaped record on `logs.otel` SHALL remain an ordinary log and SHALL NOT create a runtime finding.

#### Scenario: Posted JSON event creates an occurrence
- **GIVEN** Falco posts a JSON event with `output_fields`, `uuid`, and `tags` to the agent endpoint
- **WHEN** the agent spools it and the projector delivers the reassembled event
- **THEN** the Falco normalizer SHALL store one occurrence and update its finding
- **AND** the raw payload SHALL equal the posted JSON bytes

#### Scenario: Output fields survive the transport
- **GIVEN** a posted JSON event with `output_fields.k8s.ns.name = shop`, `output_fields.k8s.pod.name = cart-7d9f8-abcde`, and `output_fields.proc.name = sh`
- **WHEN** it is normalized
- **THEN** the occurrence SHALL record namespace `shop`, pod `cart-7d9f8-abcde`, and process `sh`

#### Scenario: NATS publish is refused after the upgrade
- **GIVEN** an unmigrated publisher still publishing to `falco.events`
- **WHEN** it publishes after the upgrade
- **THEN** NATS SHALL refuse the publish and no Falco consumer SHALL exist

#### Scenario: A Falco-shaped log is not a second ingress
- **GIVEN** a log with Falco-shaped fields published to `logs.otel`
- **WHEN** it is processed
- **THEN** it SHALL be stored as an ordinary log
- **AND** no runtime finding SHALL be created or updated

### Requirement: Oversized Falco events are chunked, reassembled, then spilled
The agent SHALL spool each accepted event under the `{"serviceradar.falco.event", 1}` contract. The OTLP relay contract SHALL NOT carry these events: it refuses one record above the 512 KiB edge-record bound, and wrapping the Falco JSON as an OTLP log would be a second encoding of `output_fields`, `uuid`, and `tags`.
An event whose edge record would exceed the 512 KiB bound SHALL be split into ordered parts. Each part SHALL be its own `EdgeRecordV1` with a freshly minted RFC 9562 UUIDv7 `event_id` inside the production-capability window. The agent SHALL reuse that `event_id` from its spool journal when it retries the same part. The Falco `uuid`, or the SHA-256 of the posted JSON when `uuid` is absent, plus `part_index`, `part_total`, and the JSON slice, SHALL travel in the contract payload and SHALL NOT be the edge `event_id`. A single-part event SHALL use `part_index` 0 and `part_total` 1. Each encoded edge record SHALL stay within 512 KiB.
The projector SHALL stage each part durably, keyed by Falco event id and `part_index`, and SHALL concatenate one slice per index before normalizing. A second delivery of the same `(falco_event_id, part_index)` or the same edge `event_id` SHALL replace that staged slice and SHALL NOT be concatenated again. The projector SHALL write an occurrence only when that concatenation equals the posted JSON and matches the carried digest. A duplicate occurrence insert SHALL be skipped when that occurrence id is already stored. The finding upsert SHALL run when that occurrence's finding update has not committed, and SHALL NOT apply the count delta again when it has. Once a part is durably staged, its source delivery SHALL be acknowledged and SHALL NOT consume further delivery attempts toward `max_deliver`. The stage SHALL be held until the set completes or the reassembly window for that Falco event expires. A complete set's stage SHALL be released only after the occurrence and the finding update have both committed. A redelivery while that window is open SHALL be acknowledged, SHALL NOT be dead-lettered, and SHALL NOT count as another delivery attempt. An expired incomplete set SHALL be published as its staged original edge records, each including its JSON slice, to the generic edge-record dead-letter, and the stage SHALL be released only after that publication is durable. After reassembly, a raw record up to 1,048,576 bytes SHALL be stored inline and a larger record SHALL be stored out-of-line as this spec requires. Size SHALL NOT refuse, truncate, or drop an event.

#### Scenario: An event above the edge-record bound is reassembled inline
- **GIVEN** a posted Falco JSON event of 600,000 bytes
- **WHEN** the agent spools it and the projector reassembles it
- **THEN** the occurrence SHALL hold those bytes inline
- **AND** no part SHALL have been refused for size

#### Scenario: An event above 1 MiB is chunked and then stored out-of-line
- **GIVEN** a posted Falco JSON event of 1,500,000 bytes
- **WHEN** it is spooled, reassembled, and stored
- **THEN** the object store SHALL hold the full posted bytes
- **AND** the occurrence SHALL carry the reference and no inline payload

#### Scenario: An incomplete part set is retained
- **GIVEN** the agent spooled part 0 of 2 for a Falco event and part 1 has not arrived
- **AND** the reassembly window has not expired
- **WHEN** the projector runs
- **THEN** no occurrence SHALL be written
- **AND** part 0 SHALL be durably staged and its source delivery SHALL be acknowledged
- **AND** that hold SHALL NOT consume further delivery attempts
- **AND** part 0 SHALL NOT be dead-lettered

#### Scenario: A redelivered part index is one slice
- **GIVEN** part 0 and part 1 are staged for a Falco event and the reassembly window is open
- **WHEN** part 0 is delivered again
- **THEN** reassembly SHALL concatenate one slice for index 0 and one slice for index 1
- **AND** the redelivery SHALL be acknowledged
- **AND** it SHALL NOT count as another delivery attempt toward `max_deliver`
- **AND** the redelivery SHALL NOT be dead-lettered

#### Scenario: A redelivered part still updates the finding
- **GIVEN** an occurrence is stored for a Falco event and its finding update has not committed
- **WHEN** one part of that event is redelivered
- **THEN** the projector SHALL skip a second occurrence insert
- **AND** it SHALL upsert the finding
- **AND** the stage SHALL be released only after that finding update commits

#### Scenario: A redelivered part of a stored finding is acknowledged
- **GIVEN** an occurrence and its finding update are both committed for a Falco event
- **WHEN** one part of that event is redelivered
- **THEN** that part SHALL be acknowledged
- **AND** no second occurrence SHALL be written
- **AND** the finding count SHALL NOT increase

#### Scenario: An expired incomplete set is dead-lettered
- **GIVEN** part 0 of 2 is retained and the reassembly window expires before part 1 arrives
- **WHEN** the projector runs
- **THEN** part 0's staged original edge record, including its JSON slice, SHALL be published durably to the generic edge-record dead-letter
- **AND** the stage SHALL be released only after that publication is durable

### Requirement: Chart wiring points the Falco DaemonSet at the agent
When `falcoIngest.enabled` is true, the Helm chart SHALL expose the in-cluster agent's Falco HTTPS port 14318 on the `serviceradar-agent` Service, SHALL NOT offer a port override, SHALL cause core to grant that agent `{"serviceradar.falco.event", 1}`, and SHALL admit `falcoIngest.namespace` to port 14318 in its network policy.
The chart SHALL render, in `falcoIngest.namespace`, the client certificate, client key, and CA for Falco's `http_output`, and the Falco settings `json_output: true`, `json_include_output_fields_property: true`, `json_include_tags_property: true`, `http_output.enabled: true`, `http_output.url` pointing at `https://<agent-service>:14318/v1/falco/events`, `http_output.mtls: true`, `http_output.compress_uploads: false`, and the certificate paths. `falcoIngest.clusterId` (default `default`) SHALL be the cluster id the agent stamps onto each event. The chart SHALL NOT render a Falcosidekick NATS user, an OTLP ingestion token, or an `otel-collector` add-on for this path. Falcosidekick collector packages SHALL NOT receive NATS credentials.

#### Scenario: Enabled chart renders the Falco http_output material
- **GIVEN** `falcoIngest.enabled = true`, `falcoIngest.namespace = falco`, and `falcoIngest.clusterId = shop-cluster`
- **WHEN** the chart is rendered
- **THEN** namespace `falco` SHALL receive the mTLS material and `http_output` settings for the agent Service port 14318
- **AND** no NATS user for Falcosidekick SHALL be rendered
- **AND** the agent configuration SHALL stamp cluster id `shop-cluster`

### Requirement: Falco delivery holds every accepted event
Operator documentation SHALL state that a Falco event is durably held from the moment the agent returns HTTP success, with every part in the agent edge spool. A source part is acknowledged once it is durably staged, and an open reassembly hold does not consume further delivery attempts. A complete set's stage is released only after the occurrence and the finding update have both committed. A duplicate part index is one staged slice. A retried publish of a committed occurrence does not count again. An incomplete set inside its reassembly window is not dead-lettered. An incomplete set whose reassembly window expires, and a reassembled delivery that would reach `max_deliver` without the occurrence and the finding update, is published as the original edge record to the generic edge-record dead-letter, and the stage is released only after that publication is durable. A failed spool admission is a non-success HTTP response. Documentation SHALL state that guarantee and SHALL NOT list a drop, truncation, or oversize refusal, and SHALL NOT name a Falco-specific dead-letter subject.

#### Scenario: Operator reads the delivery guarantee
- **WHEN** an operator reads the Falco ingestion documentation
- **THEN** it SHALL state that HTTP success means every part is in the agent edge spool
- **AND** it SHALL state that an open reassembly hold is acknowledged after a durable stage and does not consume further delivery attempts
- **AND** it SHALL state that an unfinished set is dead-lettered as its original edge records, and that the stage is released only after that publication is durable
- **AND** it SHALL NOT name a counted drop, truncation, or oversize refusal
