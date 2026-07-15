## 1. Contract and agent bridge

- [ ] 1.1 Define a versioned, typed, secret-free `awx.fetch_launch_preflight`
  request/result contract and a canonical JSON/digest implementation.
- [ ] 1.2 Implement the read-only AWX plugin verb with bounded GETs for the
  template, survey, project, inventory, associated credentials, execution
  environment, and selected hosts.
- [ ] 1.3 Double-read the template around dependent-resource retrieval and
  reject a changed, incomplete, oversized, or non-canonical response.
- [ ] 1.4 Add AWX fixture tests covering a valid projection, no secret leakage,
  pagination/bounds, every supported prompt flag, and version drift during the
  preflight read.

## 2. Secure launch gate

- [ ] 2.1 Implement `LiveAwxLaunchPreflight` ahead of
  `HardenedLaunchPlan`/`HardenedRunLauncher`, dispatching only the read-only
  preflight command through the controller's assigned agent.
- [ ] 2.2 Await terminal `AgentCommand` rows with a bounded, cancellation-safe
  database-authoritative wait; use PubSub only as a wake-up signal.
- [ ] 2.3 Canonicalize and compare the complete live template, project,
  inventory, credential, execution-environment, survey, prompt, and target
  membership contract against the approved binding.
- [ ] 2.4 Re-read actor authorization, holds, binding revision, controller, and
  target memberships after a successful preflight and before persisting a
  mutable execution.
- [ ] 2.5 Store reviewed/live/command digests in the immutable launch snapshot;
  reject all paths that could dispatch `awx.launch_job` without them.
- [ ] 2.6 Normalize timeout, agent-unavailable, malformed-result, and each
  drift family into operator-safe failures with no execution/run creation.

## 3. Authorization and operational controls

- [ ] 3.1 Enforce ServiceRadar launch and callback/CA permissions before
  preflight and again before launch; prove a mid-flight permission or hold
  change blocks the launch.
- [ ] 3.2 Document and verify the AWX ServiceRadar runner's least-privilege
  roles: read reviewed resources, execute approved templates, and no edit/admin
  rights over templates, projects, inventories, credentials, or execution
  environments.
- [ ] 3.3 Add binding-review UX/API diagnostics that identify the drifted
  category without exposing AWX secrets or raw responses.
- [ ] 3.4 Keep mutable demo callback policy disabled until the end-to-end
  preflight canary has passed; document enablement and rollback.

## 4. Verification

- [ ] 4.1 Add unit tests for positive preflight, all contract mismatch classes,
  unknown fields, duplicate resources, and malformed canonical payloads.
- [ ] 4.2 Add integration tests proving no operation/execution/PlaybookRun or
  `awx.launch_job` dispatch exists on preflight failure.
- [ ] 4.3 Add integration tests proving only a successful live preflight with
  unchanged post-read authorization creates an immutable launch snapshot and
  dispatches exactly one job.
- [ ] 4.4 Run focused Elixir, Go/WASM, formatting, OpenSpec strict validation,
  and the relevant Bazel plugin bundle tests.
- [ ] 4.5 Run a ServiceRadar-initiated, narrowly scoped demo AWX canary and
  retain redacted preflight evidence before enabling broader automation.
