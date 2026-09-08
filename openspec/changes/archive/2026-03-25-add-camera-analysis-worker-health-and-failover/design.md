## Context
Camera analysis worker registration and resolution are now platform-owned, but they still assume a mostly static fleet. Real workers will fail, restart, or become unhealthy under load, and the current dispatch path has no health memory beyond one branch attempt.

## Goals
- Add explicit health state to registered analysis workers.
- Make selection skip unhealthy workers by default.
- Allow bounded failover for capability-targeted branches when a selected worker fails.
- Preserve explicit worker identity and failover history in telemetry and result provenance.

## Non-Goals
- Building a full scheduler or load balancer.
- Replacing the existing normalized analysis result contract.
- Adding open-ended service discovery in this change.

## Decisions
### Keep health state platform-owned
Worker health should live in the registry model the platform already owns, rather than only in transient dispatch-worker memory.

### Keep failover bounded
Failover should be limited to a small number of reselection attempts and only for branches targeted by capability. Explicit worker-id targeting should fail explicitly instead of silently rerouting to a different worker.

### Reuse existing dispatch path
Health-aware selection and failover should extend the current resolver and dispatch manager rather than introducing a second branch runtime.

## Risks
### Flapping workers can cause churn
If health transitions are too sensitive, branches may bounce between workers. Health updates should stay bounded and reasoned.

### Failover can hide operator intent
If explicit worker-id targeting silently fails over, operators lose control. Failover must stay capability-only in the first slice.

### Health state can lag reality
A registry-backed health flag is useful but not perfect. Signals need to show both registry health and dispatch failure reasons clearly.
