## ADDED Requirements

### Requirement: Loaded Kernel TCP Lifecycle Attribution Is Verifiable
The system SHALL verify TCP flow attribution against the same netprobe eBPF objects loaded in production. A privileged Linux Bazel integration target MUST load those objects, complete a real loopback TCP connection, and observe the corresponding lifecycle record through the eBPF ring and userspace attribution path. Tests that construct a `FlowAttributionEvent` or ring record without loading the kernel programs MUST NOT satisfy this verification gate.

#### Scenario: Real loopback TCP connection produces owner-resolved attribution
- **GIVEN** a supported Linux host with the required BPF privileges and the production netprobe eBPF objects loaded
- **WHEN** a process completes a real loopback TCP connection after the probes report ready
- **THEN** netprobe emits a TCP attribution record containing the actual local and remote addresses and ports
- **AND** the record identifies the owning process with its PID, command name, and UID
- **AND** the loaded-program integration target fails if the record is not observed

#### Scenario: Synthetic event coverage does not replace the loaded-program gate
- **GIVEN** unit tests successfully construct or transform TCP attribution records in userspace
- **WHEN** the loaded-kernel integration target has not observed a real TCP lifecycle event
- **THEN** TCP attribution MUST NOT be reported as verified for release

### Requirement: TCP Attribution Failures Are Localized And Non-Silent
Netprobe SHALL expose bounded-cardinality evidence for TCP attribution readiness and processing at the program attach, ring observation, tuple extraction, owner resolution, userspace insert or update, and agent handoff stages. A failure or incompatible kernel condition at any stage MUST produce a stage-specific failure or unavailability outcome instead of leaving TCP attribution apparently healthy with a permanent zero-record stream. The contract MUST NOT prescribe a kernel hook, relocation mechanism, or offset change until the evidence identifies the failing boundary.

#### Scenario: Controlled stimulus produces no kernel-to-ring evidence
- **GIVEN** the loaded-program verifier has recorded successful probe attachment and readiness
- **WHEN** a controlled TCP connection completes but no TCP lifecycle record is observed in the ring
- **THEN** the verifier fails with the kernel-to-ring stage identified
- **AND** it does not classify the result as a tuple extraction or owner-cache failure

#### Scenario: Ring record fails tuple or owner resolution
- **GIVEN** netprobe observes a TCP lifecycle record in the ring
- **WHEN** userspace rejects its tuple or cannot resolve its owning process
- **THEN** netprobe increments the corresponding protocol- and stage-specific failure outcome
- **AND** the failed record is not counted as successfully inserted, updated, or handed to the agent

#### Scenario: Active kernel is incompatible with safe TCP attribution
- **GIVEN** netprobe cannot load, attach, or safely interpret the TCP lifecycle program on the active kernel
- **WHEN** netprobe evaluates protocol attribution readiness
- **THEN** it reports TCP attribution unavailable for that kernel and build combination
- **AND** it MUST NOT report successful TCP attribution readiness solely because the netprobe process remains running

### Requirement: Correlation Is Protocol-Aware And Exact-First
The core correlator SHALL preserve every deployed protocol- and topology-aware candidate family within the configured partition and time window while making precedence deterministic. A bidirectional exact TCP or UDP 5-tuple MUST rank ahead of every fallback. A wildcard-listener candidate MAY match TCP or UDP when the attribution's remote address and port are the listener wildcard and its local endpoint matches the sampled flow. A relaxed UDP service-port candidate MAY match the same endpoint IP roles and remote service port while allowing the local ephemeral port to be zero or to differ from the exporter-observed port. ICMP and ICMPv6 MUST match protocol, endpoint IPs, and time without requiring equivalent port or type/code encoding. Lower-ranked node-SNAT and public-endpoint candidates MAY map a registered agent node IP or known VIP/protocol/port to the attributed backend while preserving the applicable remote endpoint and service-port constraints. Public-endpoint candidates MUST rank below local exact, wildcard/relaxed, and node-SNAT candidates; their Gateway, LoadBalancer/ExternalIP, and other exposure classes MUST retain that relative order. No fallback candidate may displace an eligible exact candidate.

#### Scenario: Exact TCP tuple is correlated
- **GIVEN** a TCP attribution and sampled flow share a partition, time window, and bidirectional 5-tuple
- **WHEN** the core evaluates correlation candidates
- **THEN** it selects the exact TCP candidate
- **AND** it records the match strategy as exact

#### Scenario: Coalesced listener matches a local service endpoint
- **GIVEN** a TCP or UDP listener attribution has wildcard remote address and port
- **WHEN** a sampled flow matches its partition, protocol, local endpoint, and time window
- **THEN** the correlator may select the wildcard-listener candidate only when no exact candidate ranks ahead of it
- **AND** it records the match strategy as wildcard listener

#### Scenario: Exact UDP candidate outranks relaxed candidates
- **GIVEN** one exact UDP attribution and one or more relaxed UDP candidates are eligible for the same sampled flow
- **WHEN** the core ranks the candidates
- **THEN** it selects the exact 5-tuple candidate
- **AND** no relaxed candidate may displace it because of a smaller timestamp delta or newer observation

#### Scenario: UDP client observation uses the relaxed service-port match
- **GIVEN** a UDP attribution has a zero coalesced local port or a non-zero local ephemeral port that differs from the exporter-observed port
- **AND** no exact UDP candidate exists
- **WHEN** a sampled UDP flow matches the same partition, protocol, endpoint IP roles, remote service port, direction, and time window
- **THEN** the correlator may stamp the flow from that relaxed candidate
- **AND** it records the match strategy as relaxed UDP rather than exact

#### Scenario: Relaxed UDP candidate is ambiguous
- **GIVEN** no exact candidate exists and multiple process attributions satisfy the constrained relaxed UDP match for one sampled flow
- **WHEN** the core evaluates the candidates
- **THEN** it increments the ambiguous-candidate outcome
- **AND** any resulting match evidence MUST identify the relaxed ambiguity rather than presenting the result as exact attribution

#### Scenario: ICMP exporter pseudo-ports differ
- **GIVEN** an ICMP or ICMPv6 attribution and sampled flow share a partition, endpoint IPs, protocol, and time window
- **WHEN** their port or type/code representations differ
- **THEN** the correlator evaluates the candidate without requiring port equality

#### Scenario: Node-SNAT maps a pod-local attribution to its agent node
- **GIVEN** a pod-local attribution's agent has a registered node IP
- **WHEN** a sampled flow uses that node IP after SNAT and preserves the remote endpoint, protocol, applicable service port, partition, and time window
- **THEN** the correlator may select the node-SNAT candidate only after higher-ranked local candidates
- **AND** it records the match strategy as node SNAT

#### Scenario: Public endpoint maps a VIP to a backend socket
- **GIVEN** a known public endpoint maps a VIP, protocol, and port to an attributed backend socket
- **WHEN** a sampled flow uses that VIP and satisfies the direction, partition, and time constraints
- **THEN** the correlator may select the public-endpoint candidate only after higher-ranked local candidates
- **AND** it records the applicable public-endpoint strategy

#### Scenario: Exact local candidate outranks a Gateway public endpoint
- **GIVEN** an exact local candidate and a Gateway public-endpoint candidate are both eligible for one sampled flow
- **WHEN** the correlator ranks those candidates
- **THEN** it selects the exact local candidate even though the public endpoint's raw exposure rank is zero
- **AND** Gateway still ranks ahead of LoadBalancer, ExternalIP, and other candidates when comparing public endpoints with each other

### Requirement: Correlation Exposes Topology And Match Outcomes
Every correlation pass SHALL emit bounded-cardinality diagnostics for sampled flows considered, current attributions considered by protocol, exact, wildcard-listener, relaxed UDP, node-SNAT, and public-endpoint candidates, ambiguous candidates, stamped rows, and flows with no eligible topology overlap. Exported metric labels MUST NOT include agent identifiers, process identifiers, IP addresses, ports, command lines, or other unbounded payload-derived values. Sampled diagnostic logs MAY include bounded agent and partition context.

#### Scenario: Sampled flow and attribution sets have no topology overlap
- **GIVEN** current attribution rows exist for a netprobe host
- **AND** the sampled-flow set contains no eligible endpoint and time overlap with those rows
- **WHEN** the core completes a correlation pass
- **THEN** it records a `no_topology_overlap` outcome
- **AND** it records zero stamped rows for that non-overlapping set
- **AND** it does not report the outcome as either an attributed-flow success or a correlator implementation failure

#### Scenario: Candidates are considered but no row is stamped
- **GIVEN** a correlation pass considers sampled flows and one or more attribution candidates
- **WHEN** no candidate satisfies the applicable protocol-specific match contract
- **THEN** the diagnostics distinguish considered flows, considered attributions, candidate strategies, and stamped-row count
- **AND** an operator can distinguish this outcome from a correlator that did not run

#### Scenario: A row is stamped with a classified strategy
- **GIVEN** an eligible exact or fallback candidate exists
- **WHEN** the core stamps the sampled flow as `attributed_flow`
- **THEN** the stamped-row diagnostic increments
- **AND** the corresponding exact or fallback match-strategy diagnostic increments

### Requirement: Flow Attribution Admission Is Bounded Isolated And Commit-Confirmed
Core SHALL execute flow-attribution persistence through a dedicated supervised admission lane rather than inside the shared `StatusHandler` mailbox. The lane MUST be independent of retained plugin-result admission, retain the original synchronous caller reference, and reply only after the complete current-state persistence unit commits or fails. It MUST bound concurrency, total admitted item count, total retained encoded payload bytes, per-agent admitted items, queue wait, and worker runtime; item and byte totals SHALL include queued and in-flight work. This change SHALL use exactly one worker, 16 total admitted items, 64 MiB of total retained payload, four admitted items per agent, a two-second maximum queue wait, and a 20-second worker timeout. Deployments MAY configure different positive item, byte, per-agent, queue-wait, and worker-timeout bounds, but flow concurrency SHALL remain one. Queue wait MUST NOT exceed two seconds, worker runtime MUST NOT exceed 20 seconds, and their sum plus three seconds MUST NOT exceed the gateway core-call deadline. That gateway deadline MUST NOT exceed 25 seconds while the agent flow RPC deadline remains 30 seconds. Retained-byte admission MUST account for the encoded payload plus fixed envelope overhead. The lane SHALL expose queued and in-flight depth and bytes, queue wait, run duration, admission rejection, timeout, task exit, and completion-outcome telemetry. A producer batch of at most 4,096 events and 6 MiB SHALL remain one logical acknowledgement unit and MUST NOT be acknowledged as independently committed sub-batches.

#### Scenario: Accepted batch replies only after commit
- **GIVEN** a valid flow-attribution batch is admitted within every item, byte, and per-agent bound
- **WHEN** its worker persists the complete current-state attribution unit successfully
- **THEN** the lane replies to the original caller only after the database transaction commits
- **AND** the reply transfers retry ownership for that complete unit

#### Scenario: Saturated flow lane does not block unrelated status work
- **GIVEN** the flow-attribution lane is at its concurrency or admitted-capacity limit
- **WHEN** unrelated status work or retained plugin-result work reaches core
- **THEN** the shared status mailbox remains available to classify that work
- **AND** flow-attribution saturation does not consume the retained plugin-result lane's item, byte, or worker budget

#### Scenario: Admission exceeds a mandatory bound
- **GIVEN** accepting a flow-attribution batch would exceed the lane's total item, total retained-byte, or per-agent admitted limit across queued and in-flight work
- **WHEN** core evaluates admission
- **THEN** it rejects the batch with an explicit admission error
- **AND** it performs no inline flow-attribution database work in `StatusHandler`

#### Scenario: Lane telemetry accounts for admitted and rejected work
- **GIVEN** flow-attribution batches are admitted, executed, completed, timed out, or rejected
- **WHEN** the lane reports its operational state
- **THEN** its telemetry separately accounts for queued and in-flight depth and retained encoded bytes
- **AND** it records queue wait, worker duration, and the applicable completion or rejection outcome

#### Scenario: Admitted work does not reach durable completion
- **GIVEN** a flow-attribution batch has been admitted
- **WHEN** it exceeds its queue-wait or worker deadline, its task exits, or persistence fails
- **THEN** the lane replies to the original caller with the corresponding explicit error
- **AND** it does not report the batch as committed
- **AND** retrying the complete unit remains safe through idempotent current-state persistence

#### Scenario: Flow attribution cast follows the bounded path
- **GIVEN** legacy compatibility delivers flow attribution without a caller reference
- **WHEN** core accepts the cast
- **THEN** it routes the work through the same bounded flow-attribution lane
- **AND** it MUST NOT execute persistence inline in a shared mailbox
- **AND** no production agent-retained producer may use the cast as a commit acknowledgement

#### Scenario: One producer batch remains one acknowledgement unit
- **GIVEN** a valid producer batch contains no more than 4,096 events and 6 MiB of encoded payload
- **WHEN** core admits that batch for current-state persistence
- **THEN** the lane treats the complete batch as one logical acknowledgement unit
- **AND** it does not acknowledge a committed prefix while the remainder is uncommitted

### Requirement: Post-Rollout Verification Proves The Committed Artifact Chain
Release and deployment verification SHALL start after rollout completion and SHALL verify the exact deployed netprobe version and artifact before applying a new stimulus. End-to-end success MUST be established from post-rollout artifacts: a real TCP connection, TCP producer-stage evidence, a committed current-state TCP attribution row, a sampled flow with eligible endpoint and time overlap, and the resulting committed `attributed_flow` row with the expected process context. Process health, probe-attach logs, gateway acknowledgements, correlator job completion, or pre-rollout rows MUST NOT be accepted as substitutes for the final database artifact.

#### Scenario: Verification rejects a stale deployed netprobe artifact
- **GIVEN** a candidate rollout is reported complete
- **WHEN** the target host's running netprobe version or artifact identity does not match the candidate release
- **THEN** verification fails before interpreting protocol or correlation results
- **AND** rows produced by the stale artifact do not satisfy the candidate release gate

#### Scenario: Netprobe attribution change advances the native add-on artifact
- **GIVEN** a netprobe source change affects flow-attribution behavior
- **WHEN** the candidate native add-on artifact is prepared for rollout
- **THEN** the netprobe add-on manifest version and Bazel `NETPROBE_VERSION` advance together
- **AND** the bundle, version-bump, and native-add-on build gates succeed before that artifact is used for end-to-end verification

#### Scenario: Post-rollout TCP flow is attributed end to end
- **GIVEN** rollout completion and the expected netprobe artifact have been verified on the target host
- **AND** the selected connection path traverses a sampled export path visible to ServiceRadar
- **WHEN** a process completes a real TCP connection after rollout
- **THEN** TCP lifecycle evidence for that stimulus appears at the producer stages
- **AND** a committed `proto = 6` current-state attribution row newer than the stimulus contains the expected tuple and process owner
- **AND** a sampled flow newer than the stimulus contains the matching tuple and eligible time overlap
- **AND** after a correlation pass the exact sampled-flow row is committed with `event_type = "attributed_flow"` and the expected agent and process context

#### Scenario: Delivery control makes a missing TCP row meaningful
- **GIVEN** a controlled TCP stimulus has completed after rollout
- **WHEN** no TCP current-state row appears
- **THEN** verification MUST require a post-stimulus positive delivery control from the same netprobe-to-core path before classifying TCP production as failed
- **AND** absence of that control is reported as an inconclusive delivery state rather than proof of a TCP producer defect

#### Scenario: Export topology cannot observe the target host
- **GIVEN** post-rollout TCP attribution evidence exists for the target host
- **WHEN** no sampled flow involving that host exists within the eligible correlation window
- **THEN** end-to-end verification fails with `no_topology_overlap`
- **AND** it does not classify the missing stamped row as a TCP producer or persistence regression

#### Scenario: Correlator completion does not prove an attributed artifact
- **GIVEN** the correlator reports that a pass completed
- **WHEN** no exact post-stimulus `ocsf_network_activity` row is committed as `attributed_flow`
- **THEN** end-to-end verification remains failed
- **AND** counts that include workload or public-endpoint backfills do not satisfy the stamped-flow assertion
