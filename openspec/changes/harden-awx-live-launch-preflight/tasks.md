## 1. Contract and agent bridge

- [x] 1.1 Define a versioned, typed, secret-free `awx.fetch_launch_preflight`
  request/result contract and a canonical JSON/digest implementation.
- [x] 1.1.1 Add immutable, secret-free `reviewed_launch_snapshot` and
  `reviewed_launch_snapshot_digest` attributes to each approved binding version,
  validate the versioned canonical-map schema/digest, and fail closed for legacy
  digest-only bindings.
- [x] 1.2 Implement the read-only AWX plugin verb with bounded GETs for the
  template, survey, project, inventory, associated credentials, execution
  environment, and selected hosts.
- [x] 1.3 Double-read the template around dependent-resource retrieval and
  reject a changed, incomplete, oversized, or non-canonical response.
- [x] 1.4 Add AWX fixture tests covering a valid projection, no secret leakage,
  pagination/bounds, every supported prompt flag, and version drift during the
  preflight read.

## 2. Secure launch gate

- [x] 2.1 Implement `LiveAwxLaunchPreflight` ahead of
  `HardenedLaunchPlan`/`HardenedRunLauncher`, dispatching only the read-only
  preflight command through the controller's assigned agent.
- [x] 2.2 Await terminal `AgentCommand` rows with a bounded, cancellation-safe
  database-authoritative wait; reuse/factor the ControllerProvenance command
  identity/partition validation and use PubSub only as a wake-up signal.
- [x] 2.3 Canonicalize and compare the complete live template, project,
  inventory, credential, execution-environment, survey, prompt, and target
  membership contract against the immutable reviewed launch snapshot.
- [x] 2.3.1 Build the dynamic expected-target snapshot only from the selected
  current AwxHostMembership tuples (including source generation/fingerprint),
  and reject any returned host/address/inventory outside that exact set.
- [x] 2.4 Re-read actor authorization, holds, binding revision, controller, and
  target memberships after a successful preflight and before persisting a
  mutable execution.
- [x] 2.5 Store reviewed/live/command digests in the immutable launch snapshot;
  reject all paths that could dispatch `awx.launch_job` without them.
- [x] 2.5.1 Add a secret-free `AutomationAwxLaunchPreflightEvidence` resource
  with no operation/execution foreign key, then require its identity/digests in
  HardenedLaunchPlan and the persisted immutable launch snapshot.
- [x] 2.6 Normalize timeout, agent-unavailable, malformed-result, and each
  drift family into operator-safe failures with no execution/run creation.

## 3. Authorization and operational controls

- [x] 3.1 Enforce ServiceRadar launch and callback/CA permissions before
  preflight and again before launch; prove a mid-flight permission or hold
  change blocks the launch.
- [x] 3.2 Document and verify the AWX ServiceRadar runner's least-privilege
  roles: read reviewed resources, execute approved templates, and no edit/admin
  rights over templates, projects, inventories, credentials, or execution
  environments.
  - Live demo verification (2026-07-18): runner can GET reviewed template 84,
    survey, inventory 68 hosts, credential 75; after grant, project 76 Read
    returns 200; template PATCH is 403; Demo JT 7 is 403. Admin retained only
    on empty org `ServiceRadar Ephemeral` for callback credential lifecycle.
    Direct `POST .../launch/` still succeeds with template Execute (AWX does
    not separate execute-from-API vs ServiceRadar); operators must not use the
    runner principal in the AWX UI.
- [x] 3.3 Add binding-review UX/API diagnostics that identify the drifted
  category without exposing AWX secrets or raw responses.
- [x] 3.4 Keep mutable demo callback policy disabled until the end-to-end
  preflight canary has passed; document enablement and rollback.
  (`helm/serviceradar/values-demo.yaml` `automationCallbacks.enabled: false`)

## 4. Verification

- [x] 4.1 Add unit tests for positive preflight, all contract mismatch classes,
  unknown fields, duplicate resources, malformed canonical payloads, and
  legacy digest-only bindings that must remain non-launchable.
- [x] 4.2 Add integration tests proving no operation/execution/PlaybookRun or
  `awx.launch_job` dispatch exists on preflight failure.
- [x] 4.3 Add integration tests proving only a successful live preflight with
  unchanged post-read authorization creates an immutable launch snapshot and
  dispatches exactly one job.
- [x] 4.4 Run focused Elixir, Go/WASM, formatting, OpenSpec strict validation,
  and the relevant Bazel plugin bundle tests.
  - Go plugin tests: pass. Elixir unit suite (preflight/launch paths): 188 pass.
  - DB/integration on srql-fixtures scratch: 13 pass. OpenSpec strict: valid.
- [ ] 4.5 Run a ServiceRadar-initiated, narrowly scoped demo AWX canary and
  retain redacted preflight evidence before enabling broader automation.
  - Blockers remaining on demo (2026-07-18): this branch not deployed; demo
    `awx` on-demand plugin assignment on `k8s-agent` is disabled; controller
    health reports unreachable (`AWX ping returned ok=false`); zero template
    bindings and membership upserts crash in
    `AwxMembershipReconciler.field/2` on nil rows (fixed on this branch).
  - Partial live checks completed against cluster AWX with
    `serviceradar-runner` (see 3.2); accidental JT84 launch job 383 canceled.
