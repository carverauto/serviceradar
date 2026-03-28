## Context
`add-agent-command-bus` already establishes the right transport primitive: an agent-initiated long-lived control stream that can push config and commands without requiring inbound connections to the agent. Issue #2406 is the next layer above that transport. We need durable release intent, rollout policy, artifact verification, and safe activation behavior for large fleets.

The key difference from ordinary command delivery is that release management is desired-state driven. If an operator declares that a cohort should run version `v1.2.3`, offline agents still need to converge when they reconnect. That requires durable rollout state in the control plane instead of best-effort transient command dispatch.

We also need to avoid corrupting OS package ownership. Existing RPM/DEB installations should continue to own the stable service wrapper, unit files, and baseline updater assets. Mutable agent payload versions must live in ServiceRadar-managed runtime storage so self-updates do not bypass or confuse the package manager database.

## Goals / Non-Goals
- Goals:
  - Define a signed release catalog for agent binaries and updater-compatible payloads.
  - Allow operators to assign a desired version to explicit agent cohorts with bounded canary/batch rollout policies.
  - Deliver update instructions immediately to connected agents and reconcile disconnected agents on reconnect.
  - Require manifest signature and artifact digest verification before activation.
  - Support atomic activation, reconnect health checks, and rollback on failed updates.
  - Expose rollout state in inventory and UI so operators can see progress and failures.
- Non-Goals:
  - Replacing the OS package manager for full product upgrades.
  - Adding arbitrary remote shell or generic remote-debug execution.
  - Using AshOban to schedule unrelated collection jobs as part of this change.
  - Defining non-Linux package/update behavior beyond reporting compatibility metadata.

## Decisions
- Decision: Build release delivery on top of the existing agent command/control stream from `add-agent-command-bus`.
  - Why: That work already defines the bidirectional transport and push semantics we need.
- Decision: Treat release rollout as durable desired state, not fire-and-forget command dispatch.
  - Why: Offline agents still need to converge to the assigned version after reconnect.
- Decision: Model release management with three concepts:
  - `AgentRelease`: published version metadata and signed manifests for supported platform/package combinations.
  - `AgentReleaseRollout`: operator intent, cohort definition, batch policy, and pause/resume/cancel state.
  - `AgentReleaseTarget`: per-agent rollout state, timestamps, attempt counters, and last error.
- Decision: Snapshot cohort membership when a rollout starts.
  - Why: A moving target based on changing tags/filters makes staged rollout behavior hard to reason about and audit.
- Decision: Require a signed manifest that includes at least version, artifact URL, SHA256 digest, supported platform metadata, and release timestamp.
  - Why: The agent must verify both provenance and content integrity before activation.
- Decision: Embed or otherwise ship the trusted Ed25519 verification key with the agent/updater runtime and keep signing private keys outside the edge fleet.
  - Why: A compromised gateway or control-plane node must not be able to mint trusted binaries.
- Decision: Use a separate updater process to stage and activate new payloads.
  - Why: The running agent should not overwrite its own executable or mutate package-manager-owned files in place.
- Decision: Keep a stable service entrypoint installed by RPM/DEB and switch a ServiceRadar-managed `current` pointer to versioned runtime payloads atomically.
  - Why: This preserves package ownership while still enabling rollback to the previous payload.
- Decision: Roll back automatically when the updated agent fails to report healthy on the gateway/control stream within a configurable reconnect deadline (default 3 minutes).
  - Why: Fleet safety matters more than leaving nodes on a broken release.
- Decision: Persist rollout states granularly enough for operator diagnostics, including at least `pending`, `scheduled`, `downloading`, `verifying`, `staged`, `switching`, `restarting`, `healthy`, `failed`, and `rolled_back`.
  - Why: Operators need to distinguish download failures from verification failures from post-restart regressions.

## Architecture
1. Release publishing stores a signed manifest plus artifact metadata in the control plane.
2. An operator creates a rollout for a cohort and desired version with batch/throttle settings.
3. Connected eligible agents receive an update instruction over the control stream immediately.
4. Disconnected eligible agents remain `pending` until they reconnect and version reconciliation runs.
5. The agent downloads the manifest/artifact over HTTPS, verifies signature and digest, stages the payload, and hands off to the updater.
6. The updater atomically flips the active runtime pointer, restarts the service, and monitors reconnect health.
7. If the agent does not report healthy within the reconnect deadline, the updater restores the previous payload and restarts again.
8. Gateway/core persist progress and terminal status for each targeted agent.

## Risks / Trade-offs
- The updater introduces another local component that must stay compatible with multiple agent versions.
- Key rotation and trust-store updates need an operational story before broad rollout.
- Cohort snapshotting favors auditability over dynamic retargeting during an active rollout.
- Preserving package manager ownership constrains how much of the installed filesystem layout self-update can mutate.

## Migration Plan
1. Add release catalog and inventory reporting without activation.
2. Add signed manifest verification and updater staging for canary cohorts.
3. Enable staged rollouts with pause/resume/cancel controls.
4. Expand to broader fleet usage after rollback/reconnect telemetry is proven.

## Open Questions
- Should signing use an offline manual process first, or a CI-integrated KMS/HSM workflow from day one?
- Should release channels such as `stable` and `canary` be part of the initial data model, or deferred until after explicit-version rollouts are working?
