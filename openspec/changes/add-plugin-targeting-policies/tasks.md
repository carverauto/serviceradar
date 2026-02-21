## 1. Policy Resource and API
- [ ] 1.1 Add `PluginTargetPolicy` Ash resource with fields for SRQL query, plugin package/version, schedule, timeout, chunk size, and limits.
- [ ] 1.2 Add policy CRUD API endpoints and validation (including SRQL syntax checks and chunk-size bounds).
- [ ] 1.3 Add preview action to return match count, sample targets, and per-agent distribution.

## 2. Reconciliation Engine
- [ ] 2.1 Implement `PluginTargetPolicyReconciler` AshOban job.
- [ ] 2.2 Execute policy SRQL as system actor and resolve selected devices to agent ownership.
- [ ] 2.3 Group targets by agent and chunk into bounded `targets[]` batches.
- [ ] 2.4 Upsert policy-derived assignments using deterministic chunk keys; disable stale assignments.
- [ ] 2.5 Persist reconcile summary (`matched_targets`, `generated_assignments`, errors).

## 3. Assignment and Agent Config
- [ ] 3.1 Extend plugin assignment params contract to support batched target payloads.
- [ ] 3.2 Ensure agent config response includes policy-derived batch assignments.
- [ ] 3.3 Add payload-size guardrails and fallback error reporting when chunks exceed limits.
- [ ] 3.4 Implement `serviceradar.plugin_target_batch_params.v1` schema validation in assignment generation path.
- [ ] 3.5 Add deterministic chunk hashing from canonicalized target arrays.

## 4. UI and Operations
- [ ] 4.1 Add policy editor UI with SRQL query input, schedule, chunk size, and safety limit controls.
- [ ] 4.2 Add preview panel showing match count and per-agent chunk distribution.
- [ ] 4.3 Add run-now/reconcile-now actions (optionally via command bus trigger).

## 5. Tests and Verification
- [ ] 5.1 Unit tests for chunking and deterministic assignment-key generation.
- [ ] 5.2 Integration tests for reconcile upsert/disable behavior on target set changes.
- [ ] 5.3 Load test scenario for 6,000 camera targets to validate assignment counts and reconcile latency.
- [ ] 5.4 Schema validation tests for valid/invalid batch payloads and size-based rechunk behavior.
- [ ] 5.5 Validate OpenSpec change: `openspec validate add-plugin-targeting-policies --strict`.
