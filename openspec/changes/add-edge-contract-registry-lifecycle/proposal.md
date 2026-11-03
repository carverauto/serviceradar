# Change: Add the signed output-contract registry lifecycle

## Why

Gateways and core load an installation-static contract registry document, and an epoch change is a manual procedure: turn leasing off, wait for delivered slots, upgrade, turn leasing on. A record stamped with a stale epoch is withheld and caps the stream watermark. There is no signed lifecycle, readiness evidence, atomic epoch switch, planned-retirement drain, or deterministic per-contract cost API.

Split out of `unify-sweep-results-proto` on 2026-11-02, when that change's task list was reconciled against `staging`. The requirements and tasks below moved verbatim; none of them blocks shipping the durable edge pipeline or archiving `unify-sweep-results-proto`.

The moved requirement text is unchanged from `unify-sweep-results-proto`, including where it conflicts with `move-agent-telemetry-to-edge-records`. Package metadata MAY still request approved outputs and declarative processor contributions, and a producer run MAY still pin an effective assignment grant. That conflicts with Decision 8 (plugins and add-ons do not get their own contracts) and with standing output grants. USP-01 task 0.9 stays open until `add-event-writer-processor-contributions` is reconciled. "Output contract and format are sticky per producer run" still states the cohort rollback and forbids new legacy JSON output. That conflicts with Decision 7 (per-producer cutover, then one removal release). Those sentences stay verbatim.

## What Changes

- Define signed candidate, ready, active, draining, retired and security-revoked bundle states with readiness evidence and one atomic active-epoch switch.
- Define a deterministic platform-owned cost API with golden fixtures per contract, validated at the gateway and recomputed by EventWriter.
- Extend `ServiceRadar.Edge.ContractCatalog` dispatch with readiness and epoch selection.
- Remediate a compromised signing-key cohort fail-closed.

## Impact

- Affected specs: agent-connectivity, edge-producer-data-plane, ingestion-routing.
- Affected code: `ServiceRadar.Edge.ContractCatalog`, `ContractRegistryDocument`, `ServiceRadarAgentGateway.EdgeContractRegistry`, EventWriter `EdgeRecord`, Helm `edgeRecords.contractRegistry`.
- Depends on: `unify-sweep-results-proto` and `move-agent-telemetry-to-edge-records` (standing output grants).
