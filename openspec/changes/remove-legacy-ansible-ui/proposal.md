# Change: Remove legacy Ansible operator surfaces

## Why

The pre-hardening `PlaybookRun` index, detail page, and device-history table remained visible after hardened launches moved to `AutomationOperation`. The old launcher is already fail-closed, so exposing both models creates a misleading duplicate workflow, leaks migration terminology into normal operator pages, and leaves several standalone Ansible pages outside the authenticated ServiceRadar shell. Settings also presented a schedule workflow whose records are forced disabled and cannot launch through the hardened operation path.

A second pre-hardening adapter mirrored AWX playbooks into generic northbound action descriptors. Device inventory then treated those descriptors as legacy bulk actions, accepted an Ansible-specific raw `extra_vars` escape hatch, and showed the resulting retained invocations in a secondary Action History. That adapter is not the reviewed immutable-binding launch path and must not remain operator-facing.

## What Changes

- **BREAKING**: Remove the `/ansible/runs` and `/ansible/runs/:id` LiveView routes and delete their legacy index/detail modules. Retired URLs do not remain as permanent compatibility aliases.
- Make `/ansible/operations` and `/ansible/operations/:id` the only operator-facing Ansible execution history.
- Remove all user-facing legacy-model comparisons, links, badges, and copy from the operations pages and shared history components.
- Stop loading or rendering `PlaybookRunTarget` history on device details; show only canonical operation history while retaining AWX inventory recognition.
- Split device-list actions by authority and execution model: **Launch Playbook** navigates selected devices to the canonical Ansible launch route under `ansible.runs.launch`, while **Run Action** remains provider-neutral under `northbound.actions.launch`.
- Stop synchronizing or exposing retained Ansible northbound descriptors through operator catalog reads, and remove the bulk Ansible adapter, AWX-applicability shim, and raw `extra_vars` form.
- Keep generic Action History for non-Ansible northbound providers under `northbound.actions.view`, but exclude retained Ansible-adapter invocations. Canonical operations remain the sole Ansible history under `ansible.runs.view`.
- Remove the interactive Ansible Schedules and Retention tabs plus the controller run-pulse field so retained schedule, ingestion, watchdog, and retention internals are not presented as supported operator workflows; retain their stored records and backend workers for a separate architectural migration.
- Render every retained standalone Ansible page (`catalog`, `launch`, and operation index/detail) inside the authenticated operations shell.
- Authorize the launch route as creation of a canonical operation, hide launch affordances from view-only users, and enforce controller/repository settings permissions independently on every event.
- Keep disconnected LiveView mounts inert; load Ansible records and credential references only after the authenticated socket connects and current authority is refreshed.
- Reconcile user documentation and the pending Ansible integration UI requirements with the canonical operation routes.
- Preserve the scrubbed `PlaybookRun` hierarchy and retained northbound provider, descriptor, invocation, and target rows as internal evidence until a separate approved data/runtime migration replaces or retires them. This proposal removes their Ansible operator-facing presentation; it does not claim that deleting those records is safe.

## Impact

- Affected specs: `build-web-ui`; pending `add-ansible-integration` UI requirements
- Affected code: web-ng Ansible router and LiveViews, Ansible settings presentation, device-list action controls, northbound catalog/history filtering, device-detail Ansible runtime/components, Permit/RBAC mappings and labels, Ansible documentation, and focused LiveView/component tests
- Data impact: none; no historical run or northbound invocation evidence is deleted or rewritten
- Follow-up boundary: complete backend retirement requires an explicit decision on retained audit history plus migration of or removal of schedules, northbound dispatch, event ingestion, workers, OCSF projection, permissions, configuration, and schema relationships
