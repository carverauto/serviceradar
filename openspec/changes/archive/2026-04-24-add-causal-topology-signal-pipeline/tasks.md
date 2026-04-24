## 0. prop2.md Traceability Gate
- [x] 0.1 Create `openspec/changes/add-causal-topology-signal-pipeline/prop2-traceability.md` with numbered actionable items extracted from `prop2.md`.
- [x] 0.2 For each item, record disposition (`implement`, `defer`, `reject`) and rationale, plus links to spec requirements/tasks.
- [x] 0.3 Add a completion gate: implementation cannot be marked complete until every numbered item has a disposition and mapping.
- [x] 0.4 Keep `prop2-traceability.md` synchronized as tasks evolve (no stale mappings).

## 1. Spec and Contract Alignment
- [x] 1.1 Align mapper identity logic so topology links are never treated as identity equivalence (mapped `prop2` IDs required).
- [x] 1.2 Align topology evidence contracts with deterministic identity anchors and confidence classes (mapped `prop2` IDs required).
- [x] 1.3 Define and publish a versioned causal signal schema for SIEM/BMP events (mapped `prop2` IDs required).

## 2. Ingestion Pipeline
- [x] 2.1 Implement/confirm risotto BMP publication to NATS JetStream subjects for causal routing events (mapped `prop2` IDs required).
- [x] 2.2 Implement Elixir Broadway consumers for BMP causal subjects with durable replay and idempotent event handling (mapped `prop2` IDs required).
- [x] 2.3 Normalize SIEM and BMP events into a common causal signal envelope used by topology overlays (mapped `prop2` IDs required).
- [x] 2.4 Document and enforce source boundary: agent gRPC streams remain agent-originated; BMP ingress uses risotto/JetStream/Broadway (mapped `prop2` IDs required).

## 3. Topology Overlay Execution
- [x] 3.1 Ensure topology coordinate/layout computation is triggered by topology revision changes, not by every causal event (mapped `prop2` IDs required).
- [x] 3.2 Ensure causal updates recompute overlay state/classification without rebuilding structural layout when topology revision is unchanged (mapped `prop2` IDs required).
- [x] 3.3 Add backpressure/coalescing controls for high-rate BMP bursts to preserve snapshot latency budgets (mapped `prop2` IDs required).

## 4. Verification
- [x] 4.1 Add replay tests that feed BMP event bursts through JetStream/Broadway and verify deterministic causal overlay state (mapped `prop2` IDs required).
- [x] 4.2 Add regression tests that assert no identity merges are created from topology adjacency-only evidence (mapped `prop2` IDs required).
- [x] 4.3 Validate end-to-end behavior in God-View: stable coordinates with changing causal classes (mapped `prop2` IDs required).
- [x] 4.4 Run `openspec validate add-causal-topology-signal-pipeline --strict`.

## 5. Deferred Scope Preservation
- [x] 5.1 Group all `defer` items in `prop2-traceability.md` into follow-up themes (mapper refactor, topology layout refactor, advanced causal model).
- [x] 5.2 Create follow-up OpenSpec change stubs for each deferred theme with proposal/tasks/spec deltas.
- [x] 5.3 Link follow-up change IDs back into `prop2-traceability.md` so deferred items remain tracked to execution.
