## Context
The platform can now tell operators whether a camera analysis worker is healthy, flapping, alerting, or actively being probed. It still cannot answer a basic operational question: "What is this worker serving right now?" During outages or failover incidents, operators need bounded live assignment visibility so they can correlate worker alerts with relay load and current consumer branches.

## Goals / Non-Goals
- Goals:
  - Derive bounded current assignment visibility from the analysis dispatch runtime.
  - Expose assignment counts and a small active-assignment sample per worker.
  - Keep the worker registry authoritative for identity while leaving assignment state ephemeral/runtime-derived.
- Non-Goals:
  - Historical assignment analytics.
  - Per-branch control actions from the worker ops page.
  - New scheduling or load-balancing behavior.

## Decisions
- Decision: Derive assignment visibility from the dispatch manager rather than persisting branch assignments in the worker registry.
  - Alternatives considered:
    - Persist assignments on workers: rejected because assignments are ephemeral runtime state.
    - Infer assignments only from telemetry: rejected because operators need a current authoritative view.
- Decision: Expose bounded active assignment detail, not an unbounded branch dump.
  - Alternatives considered:
    - Full assignment history: rejected because it is better handled by observability storage, not the worker registry API.

## Risks / Trade-offs
- Risk: Assignment visibility can drift from runtime if branches are not cleaned up correctly.
  - Mitigation: source it from the same dispatch lifecycle that opens and closes branches.
- Risk: Operator surface becomes noisy with too much per-worker detail.
  - Mitigation: keep details bounded and summarize counts prominently.

## Migration Plan
1. Extend the dispatch runtime with a worker-assignment snapshot view.
2. Expose that snapshot through the worker management API.
3. Render assignment counts and bounded active assignments in the worker ops page.
