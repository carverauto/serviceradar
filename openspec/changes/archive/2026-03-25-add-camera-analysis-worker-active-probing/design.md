## Context
The platform already has:
- a registry of camera analysis workers
- passive health updates from dispatch failures
- bounded failover for capability-targeted dispatch

What is missing is a platform-owned view of worker liveness that updates even when no relay branch is actively sending work.

## Goals
- Periodically probe registered enabled workers from the control plane.
- Update registry health fields from probe results.
- Keep capability-based selection aligned with the latest probe state.
- Emit operational signals for probe outcomes and health transitions.

## Non-Goals
- Building a separate external service registry
- Adding per-tenant routing or partition-specific health state
- Replacing dispatch-time health updates; active probing complements them
- Adding a new operator UI in this change

## Approach
1. Add a supervised probe manager in `core-elx`.
2. Probe enabled workers on a bounded interval using the existing adapter model, starting with HTTP workers.
3. Treat a successful 2xx health response as healthy.
4. Treat timeouts, transport errors, and non-2xx responses as unhealthy with normalized reasons.
5. Update `AnalysisWorker` health fields through the existing resolver/resource path.
6. Emit telemetry for probe success, probe failure, and state transitions.

## Probe Contract
- HTTP workers are expected to expose a health endpoint.
- The endpoint may be an explicit configured URL or a derived path relative to the worker endpoint.
- Health checks are lightweight and bounded by timeout and concurrency.

## Selection Behavior
- Explicit `registered_worker_id` targeting remains fail-fast.
- Capability-based selection continues to skip unhealthy workers.
- No silent reroute is performed for explicit worker-id selection.

## Risks
- Probing too aggressively can create avoidable control-plane load.
- Derived health endpoints can be wrong for some workers, so the configuration model must allow explicit override.
- Probe flapping can cause noisy health transitions unless transitions are normalized and rate-limited through existing state fields.
