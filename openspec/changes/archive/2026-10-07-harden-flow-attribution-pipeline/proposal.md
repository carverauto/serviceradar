# Change: Harden the flow attribution pipeline

## Why

Flow attribution currently has three independent failure boundaries that can
combine into a silent end-to-end outage:

- [GitHub #4029](https://github.com/carverauto/serviceradar/issues/4029): a
  controlled TCP-connect test completed real handshakes while netprobe emitted
  no TCP attribution rows. UDP attribution was alive, so the missing TCP event
  must be localized at the loaded eBPF producer or its userspace ownership
  resolution boundary. Separately, correlation cannot succeed when sampled
  NetFlow contains no traffic involving the netprobe host.
- [GitHub #4031](https://github.com/carverauto/serviceradar/issues/4031): flow
  attribution persistence executes inside the singleton core `StatusHandler`.
  A large UPSERT or its deadlock retries block unrelated status work behind the
  same mailbox. Retained plugin-result ingestion has a comparable synchronous
  database path and no dedicated admission boundary.
- [GitHub #4030](https://github.com/carverauto/serviceradar/issues/4030): when
  either agent-retained delivery path fails, agent-gateway can move the payload into a
  small volatile buffer and still return `received: true`. The agent then
  removes data for which no durable component owns the retry.

Together these defects make a positive gateway acknowledgement, a successful
correlator run, and a healthy netprobe process insufficient evidence that an
attributed flow was actually produced and committed.

## What Changes

- Define one end-to-end flow-attribution contract from a loaded kernel probe to
  a committed `attributed_flow` row, including explicit evidence at each
  boundary.
- Add a privileged Linux/Bazel verification path for TCP socket lifecycle
  attribution and make unsupported or incompatible kernel layouts observable
  instead of silently producing zero TCP records.
- Preserve every deployed protocol- and topology-aware candidate family while
  making the intended precedence executable: exact tuple candidates rank first,
  followed by wildcard-listener, relaxed UDP service-port, node-SNAT, and
  public-endpoint strategies; ICMP remains port-independent. Public-endpoint
  exposure classes keep their relative order but receive ranks below local
  exact and fallback candidates. Add per-strategy candidate, topology-overlap,
  ambiguity, and stamped-row diagnostics.
- Move flow attribution and retained plugin-result database work behind two
  independently bounded core admission lanes. Each lane's item and retained-byte
  limits cover queued plus in-flight work, it keeps the original caller
  reference, and it replies only after its durable terminus completes.
- Make `GatewayStatusResponse.received` truthful for exactly the two
  agent-retained delivery sources (`flow-attribution` and capability-qualified
  `plugin-result`) on both `PushStatus` and `StreamStatus`: uncommitted downstream
  failures return `received: false` as a normal RPC response, while malformed
  payloads and protocol violations remain hard RPC errors.
- Formalize RPC-wide acknowledgement semantics by preventing agent-retained
  delivery from being mixed with best-effort statuses or another agent-retained
  source in the same request. Agent-retained delivery never enters the volatile gateway status
  buffer.
- Correct best-effort buffer telemetry so eviction is attributed to the entry
  actually evicted, and document that buffered best-effort entries can be lost
  across a gateway restart.
- Stop automatic replay loops for an agent-retained RPC that encounters a hard,
  non-retryable invalid-payload outcome, including equivalent local Go
  chunk/window size guards before gRPC starts, by applying an explicit terminal
  poison-drop disposition with bounded item/byte telemetry and allowing later
  valid work to progress.
- Reconcile active OpenSpec text that still describes strict UDP 5-tuple
  matching, external host-slice replay, or moving flow attribution onto the
  generic relay even though the deployed path is agent-up delivery followed by
  core-side CNPG correlation.

## Non-Goals

- Moving flow attribution to `StreamTelemetry`, the OTLP relay, or a new
  JetStream subject.
- Restoring the retired NetFlow host-slice down-to-agent architecture.
- Changing the intentional UDP client-port coalescing behavior.
- Removing any deployed wildcard-listener, UDP exporter-port, node-SNAT, or
  public-endpoint correlation candidate family. The current public-endpoint
  rank collision with exact local matches is explicitly corrected in scope.
- Splitting a 4,096-event persistence unit before measurements show that
  admission isolation and conservative concurrency are insufficient.
- Making `StatusBuffer` durable or adding a new wire field; the existing
  `received` field already represents the required negative acknowledgement.
- Changing the OTLP relay's existing hard-RPC-error contract; its edge add-on
  owns a separate durable spool and is not an agent-retained status source in
  this proposal.
- Adding an operator UI for these diagnostics in this change.

## Impact

- Affected specs: new `flow-attribution` capability and the existing
  `edge-architecture` capability.
- Affected active changes: `add-netprobe-fleet-attribution`,
  `add-host-network-visibility-sidecar`, and
  `refactor-netprobe-onto-generic-addon-contract`, plus
  `refactor-agent-nats-credential-provisioning` and
  `scale-netflow-ingest-isolation` and
  `restore-anomaly-alerting-and-surfacing`, require wording reconciliation
  with the deployed architecture. The supporting discovery note in
  `add-workload-identity-enrichment` is corrected for the same reason.
- Affected code:
  - `rust/netprobe/ebpf/`, `rust/netprobe/src/`, and the netprobe native add-on
    version/build gates.
  - `elixir/serviceradar_core/lib/serviceradar/flow_attribution/`,
    `status_handler.ex`, `results_router.ex`, and supervised admission workers.
  - `elixir/serviceradar_agent_gateway/` status processing, response handling,
    volatile buffering, and telemetry.
  - `go/pkg/agent/` retained flow-attribution and plugin-result push loops.
- Wire compatibility: no protobuf schema change. Existing agents already retain
  their pending prefix when `received` is false; the updated Go agent adds the
  longer retained-plugin deadline and terminal invalid-payload disposition for
  both remote and local preflight outcomes and must reach the controlled cohort
  before the new gateway behavior is enabled.
- Delivery order: the #4029 producer/correlation lane is independent; #4031
  establishes bounded commit-confirmed core admission, then the updated Go agent
  deploys, before #4030 exposes those failures as normal negative
  acknowledgements.
