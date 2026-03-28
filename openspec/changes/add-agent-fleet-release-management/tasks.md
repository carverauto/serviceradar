## 1. Control Plane Model
- [x] 1.1 Add Ash resources and platform-schema migrations for release catalog records, rollout plans, and per-agent rollout targets/attempts.
- [x] 1.2 Expose APIs/actions to publish signed releases, assign desired versions, and pause/resume/cancel active rollouts.
- [x] 1.3 Extend inventory/SRQL surfaces to expose current version, desired version, rollout state, last update time, and last update error.

## 2. Protocol and Orchestration
- [x] 2.1 Extend the agent control protocol with update instruction, progress, completion, failure, and rollback status messages.
- [x] 2.2 Reconcile desired version on hello/control-stream connect and deliver pending updates immediately to eligible connected agents.
- [x] 2.3 Implement cohort snapshotting, batch throttling, pause/resume/cancel semantics, and online/offline rollout transitions.

## 3. Agent and Updater
- [x] 3.1 Implement agent-side release manifest download plus Ed25519 signature and SHA256 digest verification.
- [x] 3.2 Add a separate updater process that stages versioned payloads, flips the active runtime pointer atomically, and restarts the service safely.
- [x] 3.3 Implement reconnect health deadlines and automatic rollback to the previous payload when the updated agent fails to become healthy.
- [x] 3.4 Preserve package-manager-owned assets while storing mutable release payloads in ServiceRadar-managed runtime paths.

## 4. Operator Experience
- [x] 4.1 Add fleet version distribution, rollout filters, and selected/visible cohort rollout actions to the agent inventory UI.
- [x] 4.2 Add agent detail release history, rollout timeline, failure diagnostics, and direct single-agent rollout handoff.
- [x] 4.3 Add a release-management page with auto-discovered repository-release browsing, one-click repository import, manual publish/rollout controls, supported-platform visibility, rollout compatibility preview, disabled invalid submissions, creation-time cohort validation, and detailed per-target diagnostics.
- [x] 4.4 Document release publishing, signing-key handling, rollback procedures, rollout guardrails, and rollout diagnostics.

## 5. Validation
- [x] 5.1 Add tests for signature rejection, digest mismatch, cohort snapshotting, offline reconciliation, canary batching, and rollback.
- [x] 5.2 Run `openspec validate add-agent-fleet-release-management --strict`.
- [x] 5.3 Add tests for repository-release import and secure HTTPS redirect handling for release artifacts.
