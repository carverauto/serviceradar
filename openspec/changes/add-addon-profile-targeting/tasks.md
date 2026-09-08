## 1. Data Model
- [x] 1.1 Add an `AddonProfile` Ash resource with add-on id/package/version selection, config JSON, enabled state, priority, SRQL target query, and metadata.
- [x] 1.2 Add profile-derived assignment identity fields so reconciliation can upsert/delete assignments deterministically.
- [x] 1.3 Add audit fields linking each derived assignment to the profile and last reconcile summary.

## 2. Reconciliation
- [x] 2.1 Validate and preview profile SRQL against device/agent inventory.
- [x] 2.2 Resolve matched devices to eligible agents using existing device-agent identity relationships.
- [x] 2.3 Materialize assignments with deterministic precedence and stale-assignment cleanup.
- [x] 2.4 Exclude incompatible agents using package platform/version/capability checks and record skip reasons.

## 3. UI/API
- [ ] 3.1 Add settings UI/API for add-on profiles with SRQL preview and package/config selection.
- [ ] 3.2 Show profile provenance and skip diagnostics in agent add-on views.
- [x] 3.3 Keep direct per-agent assignments available as an override/break-glass path.

## 4. Verification
- [x] 4.1 Add unit tests for precedence, deterministic assignment keys, stale cleanup, and skip reasons.
- [ ] 4.2 Add UI/API tests for profile CRUD and SRQL preview.
- [ ] 4.3 Add docs for add-on profile targeting and customer workflow.
