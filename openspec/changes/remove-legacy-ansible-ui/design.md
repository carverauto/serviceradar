## Context

ServiceRadar currently has two Ansible execution models. The original `PlaybookRun` hierarchy and `/ansible/runs*` UI landed first. Hardened targeting later introduced `AutomationOperation`, `AutomationExecution`, and immutable target evidence under `/ansible/operations*`; at the same time the unsafe `PlaybookRun` launcher was made permanently fail-closed. The old pages and device query were intentionally retained during migration and were never retired.

The retained backend is broader than stale presentation code. It still participates in scrubbed historical audit retention, event ingestion, worker registration, schedules, northbound dispatch, OCSF projection, permissions, and schema relationships. Hardened interactive launches neither create nor require `PlaybookRun`, but deleting the hierarchy without resolving those dependencies would break runtime paths and destroy historical evidence. The settings UI nevertheless exposed schedule controls and retained lifecycle configuration even though those paths do not create or govern canonical operations.

The provider-neutral northbound subsystem also contains an obsolete Ansible adapter. `AnsibleActionSync` mirrored AWX playbooks into `ActionProvider` and `ActionDescriptor` rows, the device-list bulk modal converted browser fields plus optional raw JSON into `extra_vars`, and generic Action History exposed its `ActionInvocation` evidence next to canonical Ansible operations. That workflow predates reviewed immutable bindings and exact membership preflight. Its stored rows may still be useful for audit and migration, but they are not safe launch authority or a second operator-facing Ansible history.

## Goals / Non-Goals

### Goals

- Present one Ansible execution concept to operators: an operation.
- Remove the old run pages, links, device queries, and migration-oriented language.
- Route selected-device Ansible launch through the canonical launch page instead of the northbound adapter.
- Remove Ansible descriptors, raw `extra_vars`, and Ansible invocation history from provider-neutral operator surfaces without deleting retained evidence.
- Stop presenting the fail-closed schedule, ingestion, watchdog, and retention subsystems as operator workflows or settings.
- Keep all current standalone Ansible pages inside the authenticated operations shell.
- Preserve recognition of AWX-learned devices and their ability to launch and inspect hardened operations.
- Make the backend-retirement boundary explicit instead of silently carrying presentation debt.

### Non-Goals

- Delete or rewrite historical `PlaybookRun` tables in this UI-focused change.
- Delete retained Ansible northbound provider, descriptor, invocation, or target rows.
- Remove provider-neutral non-Ansible actions or their filtered Action History.
- Re-enable the fail-closed schedule or legacy Ansible northbound launch paths.
- Adapt hardened Ansible execution into the northbound invocation model.
- Map a `PlaybookRun` ID to an `AutomationOperation` ID; no reliable relationship exists.
- Rename internal hardened-launch modules merely to remove implementation terminology that operators cannot see.

## Decisions

### Decision: Retire old routes instead of maintaining aliases

The router will no longer recognize `/ansible/runs` or `/ansible/runs/:id`. All in-product links and documentation will be updated first, and tests will assert the retired URLs do not mount a page. A redirect would preserve a permanent route whose only purpose is the migration being removed, and a detail redirect could falsely imply that unrelated identifiers map to the same evidence.

### Decision: One canonical operation history

`/ansible/operations` and `/ansible/operations/:id` remain the history routes. Useful hardened evidence—initiating actor, exact targets, controller/inventory scope, content revision, holds, diagnostics, and dispatch state—remains visible. Comparative phrases such as "secure model" and "not a legacy PlaybookRun" are removed because the UI no longer presents an alternative model.

The launch LiveView will authorize against the canonical operation resource while continuing to use the existing `ansible.runs.launch` RBAC permission name for compatibility with deployed role assignments. Renaming permission keys is a separate access-control migration and is not necessary to remove the legacy UI.

The launch route uses `:new`/`:create` Permit semantics so a custom role with only launch authority can enter and submit the workflow. That permission authorizes only the launch resolver's narrow playbook, current-binding, and current-device-membership reads; it does not grant the general catalog or operation-history surfaces. The operations index sends launchers to device inventory for an explicit target selection instead of linking to a targetless launch page. Operation viewers do not see that selection affordance unless they also hold launch authority. The settings page retains a baseline controller-read Permit gate for the shared LiveView, then refreshes current authority and checks the exact controller or repository permission before every read or mutation. Repository management grants only the controller read needed to enter that shared page; it does not grant controller mutation rights.

### Decision: Device details use operation history only

The device panel will continue to recognize current AWX membership, including the existing discovery compatibility fallback, so a valid AWX-learned device does not lose Ansible controls. It will stop querying `PlaybookRunTarget`, subscribing to legacy run updates, or deriving history state from legacy rows. The panel will show recent canonical operations and link only to operation detail pages.

The generic Action History section remains available to users with `northbound.actions.view` for non-Ansible providers. Its history read excludes `provider_type: :ansible`, including retained invocations created by the obsolete adapter. `ansible.runs.view` grants canonical Ansible operation history; it does not grant generic northbound history, and `northbound.actions.view` does not expose Ansible execution evidence.

### Decision: Device-list Ansible and northbound actions are separate

For an explicit device selection, the inventory toolbar presents two independent controls when the actor has their respective authority:

- **Launch Playbook** requires `ansible.runs.launch` and navigates to `/ansible/launch?devices=...`, where the reviewed binding, exact target memberships, current actor, and live AWX resources are revalidated.
- **Run Action** requires `northbound.actions.launch` and lists only eligible non-Ansible provider descriptors.

Neither permission substitutes for the other. The canonical Ansible path does not create a northbound invocation, and the provider-neutral action modal does not classify AWX membership, load playbook survey/git metadata, or accept Ansible `extra_vars`. Select-all-by-filter remains ineligible for canonical launch because the launch route requires an explicit immutable device set.

### Decision: Retained Ansible northbound records are storage-only

Operator catalog reads no longer invoke `AnsibleActionSync`, and the provider-neutral catalog rejects descriptors whose provider type is `:ansible` even when an older row remains enabled. The generic modal renders only its constrained provider-neutral descriptor schema; the Ansible-specific typed-variable bridge and raw-JSON escape hatch are removed. Existing Ansible provider, descriptor, invocation, and target rows are retained as internal evidence and migration inputs rather than deleted or rewritten in this UI change.

### Decision: Retire retained lifecycle presentation

`PlaybookSchedule` creation forces `enabled` to false, its enable action rejects every request pending an immutable execution delegation and reapproval, and the old launch seam cannot create a canonical operation. The run-pulse, watchdog, and retention controls also configure only retained internal evidence paths. `/settings/ansible` therefore exposes controller and repository management only: it removes the Schedules and Retention tabs, schedule actions, evaluator status, and controller run-pulse field. Existing records, workers, permissions, and schema relationships remain intact for audit and for the separate backend-retirement or hardened-scheduling decision.

### Decision: All retained Ansible pages use the operations shell

The catalog, launch, operation index, and operation detail LiveViews will each render through `Layouts.app` with the authenticated scope, current path, page title, and `shell={:operations}`. `/settings/ansible` already uses the application shell and retains only its controller and repository views.

Catalog, launch, and settings mounts initialize safe empty assigns during the disconnected HTTP render. Database-backed playbook, device, controller, repository, and credential-reference reads begin only after the LiveView socket connects. Settings refreshes current authority before those resource-specific loads so a stale session cannot expand which data is fetched.

## Risks / Trade-offs

- Old bookmarks will return not found. This is intentional and avoids preserving migration-only routing indefinitely.
- Historical pre-hardening task evidence will no longer have a dedicated browser. It remains retained internally until a separately approved audit/data decision is made.
- Retained Ansible northbound descriptors and invocations will no longer appear in Run Action or Action History. Non-Ansible provider actions and history remain available under the exact northbound permissions.
- Existing schedule records will no longer be manageable from the web UI while their execution path is fail-closed. They remain stored for audit and later migration.
- The permission key names still contain `runs`; changing deployed RBAC identifiers in this PR would create a larger compatibility migration. The user-facing model and Permit resource can still be canonicalized now.

## Backend Retirement Follow-up

Deleting the backend safely requires a separate staged change that decides whether to migrate or retire schedules and the retained Ansible northbound adapter; separates current ping/catalog ingestion from legacy job-event ingestion; drains or terminalizes retained runs, invocations, targets, and queued jobs; removes sync/pulse/watchdog/retention workers and configuration; replaces or removes OCSF and audit projections; remaps the hardened delegation foreign key; and uses a forward migration to archive or explicitly delete historical evidence before dropping resources and tables. Historical migrations must not be rewritten.
