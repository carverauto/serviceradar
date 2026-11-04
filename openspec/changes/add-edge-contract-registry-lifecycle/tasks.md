# Tasks: Add the signed output-contract registry lifecycle

## 1. Moved from `unify-sweep-results-proto`

Each task keeps its original text and number from `unify-sweep-results-proto`; its last line states what remained
when it moved.

- [ ] 1.1 (was `unify-sweep-results-proto` 1.11) Define the signed registry lifecycle and activation protocol with
  `candidate`, `ready`, `active`, `draining`, `retired`, and
  `security-revoked` states. Require readiness evidence for the target agent
  cohort, every authoritative gateway route/map generation, and every required
  EventWriter validator/cost/projector before one atomic active-epoch switch;
  assignment compilation MUST NOT grant a candidate or partially active epoch.
  Planned retirement stops new grants while exact historical bundles drain to
  bounded watermarks. Security revocation stops both production and delivery
  fail-closed until an approved safe replacement/redrive or waiver exists.
  Define rollback, stale-component fencing, bundle retention, and GC rules.
  Remaining as of the move (2026-11-02): `EdgeContractRegistry` withholds non-active
  bundles and holds security-revoked ones against a static registry document;
  the signed lifecycle, readiness evidence and atomic epoch switch are not built
  (an epoch change is a manual leasing-off procedure). Follow-up.
  Re-scoped 2026-11-03 by `enable-edge-record-pipeline-by-default`, which owns the
  signed candidate/active/draining/retired lifecycle, readiness from live core nodes
  and gateways (no `ready` state, no agent cohort), the atomic switch, drain,
  candidate retirement and stale-component fencing. Remaining here: the
  `security-revoked` state and its fail-closed remediation.
- [ ] 1.2 (was `unify-sweep-results-proto` 1.12) Define a deterministic platform-owned cost API and golden fixtures
  for each output contract. The agent SHALL compute the trusted conservative
  charge or reserve the grant maximum, the gateway SHALL validate that trusted
  stamp against the active bundle without trusting caller metadata, and
  EventWriter SHALL recompute decoded actual rows/write bytes before refund or
  commit. Underdeclared, unknown-model, overflow, or nondeterministic cost is a
  protocol failure, never authority to perform a partial write.
  Remaining as of the move (2026-11-02): cost model version 1 plus per-contract bounds
  in `ServiceRadar.Edge.ContractCatalog`; no per-contract golden cost fixtures,
  gateway stamp validation or EventWriter refund. Follow-up.
- [ ] 1.3 (was `unify-sweep-results-proto` 2.9) Advertise producer-plane protocol, registry epoch/bundle, encoder,
  validator, cost-model, route-profile, and spool-reader support in Hello and
  select one exact sticky output-contract bundle per run from the compiled grant
  plus end-to-end readiness; do not use a config hash as the gate and never emit
  a second authoritative representation for one semantic event.
  Remaining as of the move (2026-11-02): Hello advertises `sweep_lease_v1` and
  contract grants carry the registry epoch and bundle. Encoder, validator,
  cost-model and spool-reader versions are not advertised. Low confidence; may
  be superseded by the standing-grant model.
- [ ] 1.4 (was `unify-sweep-results-proto` 2.18) **Correct `projection`: use the v2 idempotency and cost model.** It
  applies the wrong idempotency key and cost model for v2 records. Align both with
  the record identities and the versioned cost contract, and test replay
  idempotence plus cost accounting against the v2 model.
  Remaining as of the move (2026-11-02): low confidence: EventWriter idempotency now
  lives in the Elixir ledger, and `go/pkg/edge/projection` supplies the agent's
  row counts. Re-scope or retire in the follow-up.
- [ ] 1.5 (was `unify-sweep-results-proto` 3.8) Load the same signed output-contract/route registry epoch as the agent
  and EventWriter. Reject unknown, revoked, digest-mismatched, route-conflicting,
  candidate, partially activated, or downstream-not-ready contracts before
  PubAck; report signed readiness for an atomic epoch switch and fence stale
  active generations. Continue planned-retirement backlog only under its exact
  draining bundle and watermark, but hold security-revoked backlog. Verify the
  provenance stamped by the trusted agent sink against the authenticated
  session and never trust guest-supplied subject, agent, scope, class, cost, or
  database destination claims.
  PARTIALLY LANDED as a deliberately NARROWED slice, so this task stays unchecked.
  `ServiceRadarAgentGateway.EdgeContractRegistry` admits every decoded record
  before publication against an installation-static snapshot
  (`AGENT_GATEWAY_EDGE_RECORD_CONTRACT_REGISTRY`) keyed by the existing
  `EdgeOutputContractRef` fields: it rejects a missing contract, a route or cost
  model the bundle does not pin, and provenance that contradicts the
  authenticated session; withholds (no publish, sequence unresolved) on no
  registry, an epoch or snapshot the gateway does not hold, an unknown or
  digest-mismatched contract, and any non-active bundle; holds security-revoked
  bundles; and takes the published route profile, traffic class and partition
  rule from the registry entry. The edge-records:v1 capability is not ready
  without a loaded snapshot.
  STILL OPEN and blocked on tasks 1.10/1.11 defining the signed format: signed
  snapshot loading, signed readiness reporting, the atomic epoch switch and
  stale-generation fencing, planned-retirement drain under the exact bundle and
  watermark, and binding network scope to the session (task 3.2's grant).
  Remaining as of the move (2026-11-02): unchanged narrowed slice (static registry
  document, epoch 2 deployed); the signed format and lifecycle remain with 1.11.
  Re-scoped 2026-11-03 by `enable-edge-record-pipeline-by-default`, which owns
  signed epoch loading, readiness reporting, the atomic switch, fencing and the
  exact-bundle drain. Remaining here: holding security-revoked backlog and binding
  network scope to the session.
- [ ] 1.6 (was `unify-sweep-results-proto` 5.10) Add registry-driven dispatch that verifies the exact output contract,
  complete bundle digest, cost model, route, and approved platform-owned
  validator/projector before decode. Preload candidate bundles and publish
  signed readiness, then atomically select only the control-plane active epoch;
  retain exact draining bundles for planned-retirement backlog and hold
  security-revoked records. Recompute decoded row/write cost before credit
  refund or side effects, reject underdeclared/overflowing cost without partial
  projection, and distinguish deployment-not-ready pause from deterministic
  payload poison. Unknown contracts never fall back to dynamic code or generic
  SQL.
  Remaining as of the move (2026-11-02): `ServiceRadar.Edge.ContractCatalog` and the
  `ServiceRadar.Edge.Projector` behaviour dispatch by `{contract_id,
  contract_version}` (#6247, #6216). Readiness, the atomic epoch switch and cost
  recompute remain.
  Re-scoped 2026-11-03 by `enable-edge-record-pipeline-by-default`, which owns
  readiness and epoch selection. Remaining here: cost recompute and holding
  security-revoked records.
- [ ] 1.7 (was `unify-sweep-results-proto` 7.7) Roll out each registry epoch as candidate, collect target-cohort agent,
  gateway-route, and EventWriter readiness, and switch it active atomically
  before issuing producer grants. Canary output contracts independently, seal
  planned-retirement grants, and retire their historical bundle only after
  agent-spool, JetStream, DLQ, redrive, and receipt-binding watermarks drain.
  Rollback MUST fence the failed epoch and MUST NOT reactivate a
  security-revoked bundle.
  Remaining as of the move (2026-11-02): follow-up (needs 1.11).
  Re-scoped 2026-11-03 by `enable-edge-record-pipeline-by-default`, which owns
  candidate rollout, readiness, activation, drain and retirement. Remaining here:
  never reactivating a security-revoked bundle.

## 2. Validate

- [ ] 2.1 Run the Go, Elixir and Bazel suites for every touched target and
  `openspec validate add-edge-contract-registry-lifecycle --strict`.
