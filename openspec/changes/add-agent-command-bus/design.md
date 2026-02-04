## Context
Agents currently poll for config updates (default ~5 minutes). “Run now” capabilities depend on forcing a config change, which is slow and brittle. We need a real-time control path for immediate actions and feedback, and a general command bus to trigger agent capabilities on demand.

## Goals / Non-Goals
- Goals:
  - Establish a bidirectional control stream from agent → agent-gateway.
  - Support push-config updates over the stream (no wait for poll).
  - Provide a generic command bus for on-demand actions with ack/progress/result.
  - Fail fast when agent is offline (no queued delivery).
- Non-Goals:
  - Guarantee command delivery for offline agents.
  - Replace existing config polling immediately (polling remains a fallback).

## Decisions
- Decision: Add a long-lived gRPC stream (agent-initiated) for control messages.
- Decision: Use the control stream for both config push and command delivery.
- Decision: Commands are persisted in CNPG as `AgentCommand` records with an AshStateMachine lifecycle.
- Decision: If the agent is offline, the API returns an immediate error and the command transitions to an `offline` terminal state.
- Decision: Command results are surfaced to the UI via PubSub and persisted state transitions (2-day retention).

## Risks / Trade-offs
- Requires new protocol surface (agent + gateway + core coordination).
- Need careful backpressure/timeout handling to avoid command pileups.
- Must preserve mTLS-only outbound connectivity (no inbound agent ports).

## Migration Plan
- Phase 1: Add control stream + command protocol while keeping config polling.
- Phase 2: Switch UI “Run now” actions to the command bus.
- Phase 3: Optionally reduce polling interval once push-config is proven.

## Open Questions
- What standard command types should be supported first (mapper discovery, sweeps, config refresh)?
