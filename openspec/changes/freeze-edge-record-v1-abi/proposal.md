# Freeze the edge record v1 wire ABI

## Why

`unify-sweep-results-proto` is 112 tasks spanning the wire contract, the agent
spool, the gateway relay, JetStream provisioning, projectors, migration, and
rollout. Six are done. The wire freeze (task 1.7) cannot ship until every one of
the other 106 is reviewed alongside it, because they are one change.

That coupling is not theoretical. The 1.6a decision slice took ten review rounds,
and a recurring cause was that each round legitimately pulled in decisions
belonging to tasks weeks downstream — the assignment mapping's repair state
machine, the recovery consumer's replay semantics, reclamation ordering. Every one
was a real finding. None of them needed to be settled to freeze a wire contract.

This change is the ABI boundary on its own: the record and frame shapes, the
identity and digest grammars, the enums, the compatibility rules, and the fixtures
that prove Go and Elixir agree. It is reviewable against one question — *is this
the byte contract we are willing to freeze?* — without also answering how the
spool reclaims segments.

## What changes

Moved here from `unify-sweep-results-proto`:

- **1.1–1.7** — the v1 contracts, compatibility rules, codegen and cross-language
  fixtures, the loss-classification span freeze (1.6a), and the freeze gate (1.7).
  1.7's prerequisites are now **all owned here**; an earlier draft blocked it on the
  durable mapping's existence and the producer-facing API freeze, both downstream,
  which would have left it unblockable by construction.
- **1.13–1.15** — the restack prerequisite, the transport-provenance header
  grammars, and the cross-language vector inventory.

Two structural edits, not lifts:

- **The ORIGINAL pre-split 2.20 is folded into 1.6a.** (The downstream change reuses
  the number 2.20 for a distinct runtime task, which is not folded.) The proto shape, both runtimes' validators, the
  exact-received-byte checks, and the fixtures now land atomically. Splitting them
  allowed a frozen shape to ship without the validators that enforce it.
- **1.3 is split.** The ABI half — the authoritative assignment-record contract,
  the `SweepObservationBatchV1` correlation matrix, and the assignment-mapping KEY
  (the KEY ONLY -- the tagged value shape is owned downstream)
  — is here, because the span omits execution and plan identity on the strength of
  that key. The durable storage, replay/repair state machine, conflict resolution,
  retention, GC, and lookup-outcome transitions stay downstream: they are runtime
  behaviour over a frozen key.

## What stays in `unify-sweep-results-proto`

Tasks 1.8–1.12, **1.16 and the new 1.16a** (the producer-facing sink/run API
freeze, displaced from 1.7), **2.20** (the durable assignment mapping — the runtime
half of the split 1.3), and sections 0 and 2–8. That change becomes the runtime
change and depends on this one.

## Spec scope

The split is at **clause granularity, not whole requirements** — the originals mix
wire facts with runtime lifecycle, so moving them intact would have made this change
normatively own registry activation, EventWriter enforcement, journal and PubAck
behaviour, and GC, none of which it has tasks for.

Five mixed requirements were divided:

| Requirement | ABI keeps | Runtime keeps |
| --- | --- | --- |
| Output contracts | the exact `EdgeOutputContractRef` a record carries | the registry and its candidate/ready/active/draining/retired lifecycle, activation, drain, revocation, fencing, GC |
| Producer provenance | which fields are authoritative, and that payload claims and output permissions are not | sink derivation and EventWriter comparison/replacement |
| Record identity | the four identities and their digests | which components preserve, encode, or re-hash those bytes |
| Record authorization | that authorization is four separate decisions, and the wire-carried values only: `EdgeSourceAuthorizationKind`, `EdgeRecordDispositionKind`, the `DeliveryMode` constants | the historical-proof, projection, and internal publication vocabularies; the authorization matrix and its fixed evaluation order |
| Service ingress | the `service_slot` tuple, its validity rules, fresh-only scope, and three transport transcripts | the publisher journal, allocation, PubAck reclamation, lane sealing, and credential mapping |

Six requirements were already wire-only and moved whole. A trimmed twelfth states
the assignment mapping's key ONLY (the tagged value shape is owned downstream, and
so is its durable behaviour)
task 2.20.

Two frame/lane requirements moved **up** from the sibling capabilities, because
task 1.7 freezes the frame and lane-open handshake and they define it:
`ingestion-routing`'s byte-bounded/versioned records and frames, and
`agent-connectivity`'s bidirectional capability negotiation. Session replay
semantics stay downstream — that is behaviour, not frame shape.

## Impact

- No code moves. This is a planning boundary, not a refactor.
- `#4713`–`#4718` re-root onto `staging` under this change.
- `#4734` (compression admission) is held until after the schema churn.
- `#4685` stays held; it lands the runtime change.
