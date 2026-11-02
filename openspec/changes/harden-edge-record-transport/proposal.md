# Change: Harden the edge-record transport and gateway

## Why

The gateway decodes edge records through `WireDecode` and publishes exact bytes, but the gRPC codec still buffers a declared message length before checking it, compression is not refused on the edge lane, the sender has one lane and no per-lane pools, retained gateway memory is unproven on a long-lived lane, and the projection fence refuses instead of committing a ledger-only outcome.

Split out of `unify-sweep-results-proto` on 2026-11-02, when that change's task list was reconciled against `staging`. The requirements and tasks below moved verbatim; none of them blocks shipping the durable edge pipeline or archiving `unify-sweep-results-proto`.

## What Changes

- Add the edge-ingest gRPC codec that bounds length before buffering and refuses compression.
- Add per-lane sender RPCs and pools, byte-bounded fair gateway queues, and the dead-owner reservation fix.
- Prove the retained-memory bound, stamp and verify transport provenance, and keep the two watermarks separate with cross-language vectors.
- Commit `ledger_only` on a fence race, with a concurrent CNPG race test.

## Impact

- Affected specs: edge-architecture, edge-producer-data-plane, ingestion-routing.
- Affected code: `ServiceRadarAgentGateway` edge ingest and publisher modules, `go/pkg/edge/sender`, `go/pkg/edge/gwprefix`, `ServiceRadar.Edge.SweepProjection`.
- Depends on: `unify-sweep-results-proto`.
