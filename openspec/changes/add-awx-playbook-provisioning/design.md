## Context

Paths below are relative to the repository root; `A/` abbreviates
`elixir/serviceradar_core/lib/serviceradar/automation/ansible/`.

### What exists today (read from code)

| Fact | Source |
| --- | --- |
| A repository is a public HTTPS git URL and a branch or tag. Sync records status and diagnostics, not a commit. | `A/playbook_repository.ex:128`, `A/git_catalog_sync_worker.ex:225`, `docs/docs/ansible-provisioning-api.md:58` |
| Git-sourced catalog rows are not launchable and nothing links a repository to an AWX project. | `docs/docs/ansible.md:269`, `A/playbook.ex:358` |
| AWX mutations today: job launch, job cancel, ephemeral callback credential create and delete. | `go/cmd/wasm-plugins/awx/main.go:398`, `:1087`, `:1819` |
| Controller credentials are split by purpose: sync, execution, callback. A caller cannot choose the purpose of a verb. | `A/controller.ex:13`, `A/awx_client.ex:151`, `:162`, `:171` |
| A binding review needs the template, project, inventory, credential and execution-environment identifiers, 1 to 100 already approved memberships, and a caller-supplied `content_sha256` and `input_schema`. | `A/awx_binding_review.ex:26`, `:74`, `:257`, `:273` |
| A binding approval lives 60 seconds to 24 hours, default one hour. | `A/awx_binding_review.ex:393` |
| The reviewed template must have the survey enabled, both dispatch-marker fields, `ask_variables_on_launch` false and limit prompting on. | `A/awx_launch_contract.ex:630`, `:640`, `A/dispatch_marker_contract.ex:22` |
| Live preflight requires the project to be clean with update-on-launch off and the execution environment pinned by digest, and compares live AWX state with the reviewed snapshot. | `go/cmd/wasm-plugins/awx/launch_preflight.go:917`, `:1065`, `A/awx_launch_contract.ex:524` |
| Binding prepare, create and revoke, and membership approval, require `ansible.controllers.manage` and a human principal. | `A/awx_binding_review.ex:125`, `docs/docs/ansible-provisioning-api.md:36` |
| Membership dispositions are `unlinked`, `proposed`, `approved`, `quarantined`. Only `proposed` can be approved. | `A/awx_host_membership.ex:259`, `A/changes/approve_awx_host_membership.ex:76` |
| Ansible settings have two tabs: controllers and repositories. Memberships and bindings have no page. | `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/ansible_live.ex:34` |
| Ten Ansible permissions exist; `ansible.controllers.provision` does not yet. | `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex:983` |
| The public playbook repository carries one catalog file, schema `serviceradar.automation.catalog/v1`, and two agent package playbooks, one per package family. | `carverauto/serviceradar-ansible` at its `main` branch, read 2026-11-10 |

### Constraints inherited from approved work

- Every unsafe AWX request uses a grant that authorizes one mutation with an exact,
  server-built body; every verb has an explicit endpoint mapping; no generic `/api/v2/`
  fallback (`harden-ansible-awx-targeting`).
- The execution principal has no edit or admin rights over templates, projects,
  inventories, credentials or execution environments; a drifted object is never
  auto-repaired; only an authorized reviewer creates a reviewed snapshot
  (`harden-awx-live-launch-preflight`).
- Every edit of a template invalidates its reviewed binding (`harden-ansible-awx-targeting`,
  design).
- Secure launch inputs come only from the approved binding's typed non-secret schema; git
  `vars_prompt` and AWX `survey_spec` are not the launch contract; `ansible_*` and magic
  variables are rejected (`add-ansible-integration`, `harden-ansible-awx-targeting`).
- SSH, become and vault secrets are never stored in ServiceRadar
  (`refactor-unified-credential-management`).
- No Helm-only behaviour: hosted tenants have their values rendered by a control plane.

## Goals / Non-Goals

Goals:

- "Register repository, pick playbook, review, launch" works without the AWX UI, given a
  controller whose inventory, execution environment and machine credential already exist.
- Nothing becomes launchable without the existing human approval of a binding.
- The security posture is kept whole: reviewed bindings with content digests, exact
  memberships, human-principal approval, immutable launch snapshots, brokered credentials.
- An operator can tell, for any device, whether it is launchable and what to do if not.

Non-goals and first-version limits are listed at the end.

## Decisions

### Decision 1: an automation is an immutable, reviewed description of one playbook

New resource `Automation` with immutable `AutomationRevision` rows. A revision holds:

- repository id, resolved commit (40 hex), and one or more variants, each a playbook path
  with the SHA-256 of that file (an automation without variants has exactly one), and a
  digest over every file under the repository at that commit that those playbooks can load
  (the content digest);
- the typed input schema (Decision 4);
- references, by controller-scoped AWX id, to one inventory, one execution environment,
  one machine credential, and optionally an instance group;
- run modes offered: `run`, and `check` when the catalog entry or the author declares
  native check-mode support;
- the automation's name and the catalog entry it came from, when any.

Repository sync is extended to record the resolved commit and per-file digests. A
revision always names a commit, never a branch or tag: the approved targeting requirement
forbids moving refs, and a commit is what a reviewer can actually review.

Alternative rejected: derive the template directly from a repository row with no
intermediate resource. That leaves nowhere to hold the reviewed input schema and the
object references, and makes "what changed since the last review" unanswerable.

### Decision 2: what ServiceRadar owns and what it only references

| AWX object | Relationship | Why |
| --- | --- | --- |
| Project | **Owned.** One per repository and commit, shared by every generation at that commit and never edited. | It is a pure function of data ServiceRadar holds. |
| Job template | **Owned.** One per generation, variant and offered run mode. | Same; and its exact shape is dictated by the launch contract. |
| Survey of an owned template | **Owned.** One per owned template. | Derived from the input schema plus the dispatch markers. |
| Role grants on owned objects | **Owned**, exactly two kinds, to the execution principal: Execute on every owned template, and Read on each owned project. | The minimum the execution principal needs (`docs/docs/ansible.md:172`). |
| Organization | Referenced. | Creating organizations is tenancy administration. |
| Inventory and hosts | Referenced. | An approved requirement says ServiceRadar does not push devices into AWX inventory. |
| Execution environment | Referenced, and must be pinned by image digest. | Its registry credential and pull policy belong to AWX administration. |
| Machine and SCM credentials | Referenced. | Their secrets must never enter ServiceRadar. |
| Instance group, labels, notification templates, schedules | Referenced or unused. | Not needed for the workflow. |

ServiceRadar never grants a role on an object it does not own, never changes a referenced
object, and never deletes anything it did not create.

Ownership is recorded per managed object as the open change requires (controller, type,
upstream id, last observed configuration). In addition each owned object's name is
deterministic and unique. A project's name is a fixed prefix, the repository slug and the
commit, so there is exactly one owned project per repository and commit. A template's name
is a fixed prefix, the automation slug, the first characters of the revision digest, the
generation number, the variant and the run mode; the generation number is recorded before
the create is sent. AWX enforces name uniqueness within an organization for projects and job
templates, so after a lost create response the exact name answers "did it succeed" without
a second create.

### Decision 3: generations are immutable; nothing bound is ever edited

A revision produces one generation of objects: its job templates, their surveys and their
Execute grants, plus a reference to the project for its repository and commit. Changing
anything (commit, playbook, input schema, references) creates a new revision and a new
generation with new job templates. A new revision at an unchanged commit references the
existing project for that commit and does not edit it; a new commit gets a new project. The
previous generation keeps serving its approved bindings until they are revoked, expire,
or are superseded by approved bindings on the new generation; then it is retired.

This is the only arrangement that satisfies three approved rules at once: an edit
invalidates a reviewed binding, drift is never auto-repaired, and a reviewer approves an
immutable snapshot. It also makes upgrade safe: the old automation keeps working until a
human approves the new one.

Alternative rejected: patch the template in place and re-request review. During the gap
the automation is unusable, a failed patch leaves a half-edited template under an approved
binding, and "ServiceRadar edited a reviewed template" is exactly what live preflight
exists to detect.

### Decision 4: the typed input schema is the source of the survey, not the reverse

The input schema is authored in ServiceRadar: taken from a catalog file when the
repository carries one, otherwise written by the automation's author with parsed playbook
variables offered as suggestions only.

- Field types: text, textarea, integer, float, single choice, multiple choice. These are
  the types the launch form already renders (`docs/docs/ansible.md:328`).
- Constraints: required, default, minimum and maximum, length, a regular expression, and
  "all or none" groups for inputs that only make sense together.
- No secret type. Variable names matching `ansible_*`, inventory or play magic variables,
  and the dispatch-marker names are rejected.
- Only declared names reach AWX. The template is created with
  `ask_variables_on_launch` false, so undeclared extra variables are dropped by AWX too.

The AWX survey is rendered from the schema: the two dispatch-marker fields exactly as the
marker contract defines them, then one question per input. AWX surveys cannot express
regular expressions or cross-field rules, so ServiceRadar validates the full schema before
dispatch and the survey carries the subset AWX can enforce. A playbook is expected to
validate its own inputs as well; the worked example does.

The binding review then receives the schema and the content digest from the revision.
Today both are whatever the caller types.

### Decision 5: a provisioning principal that cannot launch

A fourth controller credential purpose, `provisioning`, beside sync, execution and
callback, declared by the AWX package manifest as unified credential management requires,
stored through a restrictive foreign key and listed in credential usage.

| Principal | May | May not |
| --- | --- | --- |
| Sync | Read inventories, hosts, groups, projects, templates. | Mutate anything. |
| Execution | Read reviewed objects, launch approved templates, cancel its jobs. | Edit or administer any object. |
| Callback | Manage ephemeral callback credentials in its dedicated organization. | Anything else. |
| **Provisioning (new)** | Create projects and job templates in one organization; start and read a project update; set a survey; attach a referenced credential to an owned template; grant the two role kinds on owned objects; delete owned objects. | Launch or relaunch any job; read or create credentials' secrets; create or edit inventories, hosts, organizations, users, teams, execution environments; grant any role on an object ServiceRadar does not own. |

Two layers enforce the right-hand column. In ServiceRadar, provisioning verbs map only to
the provisioning purpose, each with an exact method and path, a one-mutation grant and a
server-built body; the launch endpoint is not reachable under that purpose. In AWX, the
operator gives the provisioning user Project Admin and Job Template Admin on the chosen
organization, Use on each referenced inventory and machine credential, and Read on the
execution environment, and nothing system-wide.

One caveat is stated rather than hidden: in AWX, administering a job template implies
being able to execute it. AWX cannot express "create but not launch". The ServiceRadar
broker policy is therefore the control that stops the provisioning credential from
launching, and a dedicated organization for owned objects (Open Decision 3) limits what
that credential can administer to objects ServiceRadar created. (Inference from AWX role
semantics, not from this repository's code; a task verifies it against each supported AWX
version before the roles are documented.)

The readback that feeds the review (Decision 7) uses the execution principal, not the
provisioning one. Review evidence then comes from the same eyes that will launch, and a
provisioning credential that lied about what it created would be caught.

### Decision 6: provisioning is a durable, resumable sequence of single mutations

For one revision, in order:

1. Find the project for the repository and commit, or create it (pinned commit,
   update-on-launch off, override off). An existing owned project is used as found and is
   never edited or duplicated. When it is drifted or missing, provisioning at that commit
   stops and reports it (Decision 8). When an AWX project of that name exists and is not
   owned, provisioning stops and names the conflict; it is never adopted.
2. When the project has not yet reported the pinned commit as its synced revision, start
   one project update and wait until it does; fail if it reports anything else. Grant Read
   on the project to the execution principal when that grant does not already exist.
3. Find or create one job template per variant and offered run mode with the exact
   contract flags.
4. Set the survey on each template.
5. Attach the machine credential to each template.
6. Grant Execute on each template to the execution principal.
7. Read everything back with the execution principal and compute the projection digest.

Each step is one typed agent command under the open change's contract. Each is idempotent
by construction: "find" is by recorded upstream id, else by exact deterministic name. A
step whose outcome is unknown stays visibly unresolved until an exact read proves it. A
failed sequence leaves the objects it created recorded as owned and unbound; they are
harmless (no binding, so not launchable) and are either completed by a retry or retired.

### Decision 7: the result enters the existing review as a prepared, unapproved binding

After step 7 ServiceRadar calls the existing binding review "prepare" once per owned
template, with the template, project, inventory, credential and execution-environment
identifiers, and with the content
digest and input schema from the revision. Each owned template has its own binding
review; a template is launchable only when its own binding is approved, and the automation
is launchable in a given variant and run mode only through that approved template. The
automation shows "awaiting review" for each template not yet approved.

- Approval is the existing action, by a human principal, with the existing permission and
  the existing live checks. Provisioning success confers nothing.
- The reviewer sees repository, commit, playbook path, content digest, input schema,
  referenced objects and the live readback, and for a new revision of an existing
  automation, a comparison with the currently approved revision.
- The existing review needs approved memberships to attest against
  (`A/awx_binding_review.ex:74`). When none is approved for the chosen inventory, the
  automation says so and links to membership review; it does not fabricate one.
- Approvals expire within 24 hours by existing policy. That is kept. The automation page
  offers renewal, which is the same review against the same revision: the reviewer
  confirms unchanged evidence rather than re-entering it.

Separation of duties is available without new machinery: provisioning needs
`ansible.controllers.provision`; approval needs the binding permission. A deployment that
wants two people gives the two permissions to different roles (Open Decision 5).

### Decision 8: drift is reported, never repaired

A read-only reconciliation compares each owned object's live projection with the one
recorded at provisioning. Live preflight already does this at launch for bound objects;
reconciliation makes it visible before someone tries to launch.

| Observation | State | What ServiceRadar does | What the operator can do |
| --- | --- | --- | --- |
| Matches | `in_sync` | Nothing. | Nothing. |
| Differs | `drifted` | Reports the changed fields. Launch is already blocked by preflight. | For a job template: **Replace**: provision a fresh generation from the same revision, then review. Or **Release**: give up ownership; the binding is revoked and the object is left as found. |
| Gone | `missing` | Reports it. | For a job template: Replace or Release. |
| Unknown after an uncertain write | `unresolved` | Keeps reading; never repeats the write blindly. | Wait, or Release. |

A project is never replaced: one commit has exactly one owned project, and a second would
duplicate it. A drifted or missing project is reported and blocks provisioning at that
commit until an operator restores it in AWX to its recorded state, or releases it.
Releasing a project revokes the bindings of every generation that references it and leaves
the project as found; provisioning at that commit then creates the project only when no
AWX project of that name exists.

There is deliberately no "accept the live values" action. Absorbing an out-of-band edit
into a reviewed contract is what the preflight change forbids; the supported way to change
an automation is a new revision.

### Decision 9: retirement and deletion

- Retiring a generation revokes its bindings (existing action), removes the Execute grant
  on each of its templates and deletes them, and, when no other owned template uses the
  project, removes the project's Read grant and deletes the project.
- Deletion is refused while an operation that references the generation is not terminal.
- AWX job records outlive their template; ServiceRadar's own operation history does not
  depend on the template existing.
- Deleting an automation retires all of its generations first. Deleting a repository or a
  controller is refused while an automation uses it (existing guarded-deletion pattern).
- An owner who would rather keep retired templates in AWX can choose that (Open
  Decision 6); the default deletes, because an orphaned launchable template with a
  dedicated Execute grant is a liability.

### Decision 10: target readiness is one computed answer

For a device and a controller (optionally an automation), readiness is computed from the
same predicates launch uses, so it cannot disagree with launch. When several reasons apply,
the first row in table order is reported. `no_address` precedes `quarantined` and
`needs_membership_review` because approval of a membership without an address is refused,
so the review remedy cannot succeed until the address is fixed:

| Reason | Meaning | Operator action |
| --- | --- | --- |
| `skipped_by_sync` | AWX has a host of that name but sync skipped it for lack of an anchor. | Give the host an address or MAC in AWX. |
| `not_in_inventory` | AWX has no host for the device in any inventory of this controller. | Add the host to an AWX inventory. |
| `ambiguous` | More than one membership or more than one device matches. | Choose the membership, or fix the duplicate. |
| `host_disabled` or `not_current` | Disabled in AWX, or absent from the last complete sync. | Fix in AWX. |
| `no_address` | The AWX host has no usable `ansible_host`. | Set it in AWX; the next sync picks it up. |
| `quarantined` | The membership was quarantined; its recorded reason says why. | Review the evidence and release it (`add-awx-membership-quarantine-release`), then approve the resulting proposal. |
| `needs_membership_review` | A `proposed` membership exists. | Approve it on the membership page. |
| `held` | An active target hold exists. | Clear the hold through its own gate. |
| `no_approved_binding` | The template for the device's variant and the chosen run mode has no current approved binding. | Review that template's binding. |
| `launchable` | An approved, current, enabled membership with an address exists in an inventory the binding allows. | None. |

Two additions make the table reachable:

- **Membership review page.** Lists memberships by controller, inventory or device,
  current and not, with disposition, address, evidence and the approve action that exists
  today only in the API.
- **Reviewed exit from quarantine.** Delivered by `add-awx-membership-quarantine-release`:
  a human with the membership permission releases a quarantined row, which becomes
  `proposed` when exactly one device matches now, `unlinked` when none does, and is
  refused when several do. Each quarantine records its reason, and each release records
  who, when, the prior reason and the evidence. It never returns to `approved`, so the
  approved rule "no device that later matches the same AWX host inherits the approval"
  holds: a fresh approval is always required.

`not_in_inventory` still ends outside the product. That is the honest state of the
approved design, and Open Decision 2 asks whether to change it.

### Decision 11: first-party catalog

A catalog entry is a file in a playbook repository
(`serviceradar.automation.catalog/v1`, extended with an `automations` section: playbook
path, title, input schema, run modes, supported targets, transport needs). ServiceRadar
parses catalog files on repository sync at the resolved commit.

"First-party" means two things, both code defaults and not chart values:

- ServiceRadar ships knowing the public repository URL and, per release, the commit it was
  tested with. Registering it is one click or one API call; it is not registered silently.
- Catalog entries from that repository at that commit are labelled as tested with the
  running release. An operator may still pin another commit; the label then disappears.

Catalog files do not bypass anything. An entry becomes an automation revision, is
provisioned, and waits for the same human review.

### Decision 12: worked example, "Install or upgrade the ServiceRadar agent package"

The public repository has two playbooks, one for Debian-family and one for Red Hat-family
hosts, sharing tasks. The catalog entry declares one automation with two variants.

Inputs (all optional except where noted; names are the playbooks' own):

| Input | Type | Rule |
| --- | --- | --- |
| `serviceradar_version` | text | Release version pattern. Required when a package URL is given. Defaults to the running ServiceRadar version rather than "latest". |
| `serviceradar_agent_package_url` | text | HTTPS URL. All-or-none with the digest. |
| `serviceradar_agent_package_sha256` | text | 64 hexadecimal characters. All-or-none with the URL. |

Not inputs, and so unreachable from a launch: the play's host pattern, the release API
base URL, certificate validation, package and service names.

End to end:

1. An administrator registers the public repository (first-party, pinned commit). Sync
   records the commit and digests and finds the catalog entry.
2. They open the entry, choose the controller, the inventory that holds the target hosts,
   a digest-pinned execution environment and a machine credential with privilege
   escalation, all picked from what the controller already has. They create the automation.
3. ServiceRadar shows the plan and, on confirmation, provisions it. With two package
   families and both `run` and `check` offered, the plan is one project, four job templates (one per package family and run mode), a survey
   on each, an Execute grant on each of the four templates, and one Read grant on the
   project.
4. A reviewer opens the prepared binding for each of the four templates, sees the commit,
   digests, inputs and live readback, and approves.
5. An operator selects devices and the automation. Readiness explains any device that is
   not launchable. The planner sends each device to the variant for its package family
   when the device's operating system is known and asks otherwise.
6. The operator runs in check mode first, then for real, entering the version. The
   existing prepare, preflight, launch and status path does the rest.

No step touches the AWX UI. The prerequisites that remain in AWX are the ones this change
deliberately does not own: the inventory and its hosts, the execution environment, the
machine credential, and the one-time role grants for the provisioning user.

### Decision 13: surface

API, under the existing `/api/admin` boundary and the open change's conventions
(idempotency key on create, ETag on mutation, secret-free asynchronous status):

| Resource | Operations |
| --- | --- |
| `ansible-catalog-entries` | List and read entries found in registered repositories. |
| `ansible-automations` | Create, read, list, delete; `revisions` create and read; `plan`; `provision`; `retire`. |
| `ansible-awx-resources` (from the open change) | Read owned objects with state and drift; `replace`; `release`. |
| `ansible-awx-references` | Read-only pick lists of inventories, execution environments and credentials on a controller (names and ids, no secrets). |
| `ansible-target-readiness` | Read readiness for devices and a controller, optionally an automation. |
| `ansible-memberships` | Adds listing by device and non-current rows, full non-secret evidence, and `release`. |

Terraform: `serviceradar_ansible_automation` (desired revision; apply provisions and
waits; exposes the pending review id and binding state of each owned template and owned-object ids),
`serviceradar_ansible_catalog_entry` and reference data sources. Apply never approves,
never launches, and a refresh never mutates, as the open change already requires.

UI: an **Automations** tab in Ansible settings (catalog entries, automations, plan,
provisioning progress, drift, retire); a membership review page; binding review and
renewal reachable from the automation; readiness on the launch page and the device panel.

Permissions:

| Permission | Covers | Default |
| --- | --- | --- |
| `ansible.controllers.provision` (from the open change) | Create and revise automations, provision, replace, release, retire. | admin |
| `ansible.controllers.manage` (existing) | Membership approval and release; binding prepare, approve, revoke. | admin |
| `ansible.catalog.view` (existing) | Read catalog entries, automations, readiness. | all |
| `ansible.runs.launch` (existing) | Launch. | operator |

No permission implies another. Provisioning and review actions require a human principal,
as binding review does today.

Audit events, all secret-free and carrying the initiating principal: automation created,
revision created, provisioning requested, each object created, role granted, provisioning
completed, failed or unresolved, drift detected, replaced, released, retired, and
(closing an existing gap) membership approved and binding approved. A membership released
from quarantine is recorded by the release record of
`add-awx-membership-quarantine-release`.

### Decision 14 (optional, second phase): inventory sources from the pinned project

An owned inventory source of type "sourced from a project", pointing at an inventory file
in the same pinned project, attached to a referenced inventory, with update-on-launch off.
It lets a repository carry its own static inventory. It does not let ServiceRadar write
hosts, needs no cloud credential, and is not required by the workflow above. Cloud and
dynamic inventory sources are out of scope.

## Approved statements this change relaxes

| Statement | Where | Effect of this change |
| --- | --- | --- |
| "Operators must pre-create AWX projects + job templates that ServiceRadar will reference. ServiceRadar does not manage AWX configuration in v1." | `openspec/changes/add-ansible-integration/proposal.md:93` | Projects and job templates for automations may be created by ServiceRadar. Pre-created objects remain supported through the existing review. |
| Non-goal: "Let ServiceRadar create arbitrary AWX inventory hosts/templates/credentials." | `openspec/changes/harden-ansible-awx-targeting/design.md:20` | Still true for hosts and credentials, and for arbitrary templates. Templates are created only in the one typed shape the launch contract accepts. |
| Non-goal: "Configure AWX projects, credentials, inventories, templates, or execution environments." | `openspec/changes/publish-ssh-ca-ansible-enrollment/design.md:18` | That change's content stays configuration-free; this change is the binding step it defers to, for non-callback content only. |
| "The settings UI SHALL expose controller and repository management only." | `openspec/changes/remove-legacy-ansible-ui/specs/build-web-ui/spec.md:106` | Ansible settings also expose automations. The retained-internals prohibition in the same requirement is unchanged. Because that requirement lives in an open change, a task amends its wording there (or in the archived spec, whichever exists when this lands). |

Statements that are **not** relaxed: ServiceRadar does not push devices into AWX
inventory; the execution principal cannot edit; drift is never auto-repaired; no secret
launch inputs; no moving refs.

## Risks / Trade-offs

- A provisioning credential is a new high-value secret. Mitigation: its own purpose,
  one-mutation grants with exact bodies, an organization-scoped AWX role set, readback by
  a different principal.
- Immutable generations accumulate AWX objects. Mitigation: automatic retirement of
  superseded generations; a count per automation in the UI.
- A 24-hour approval lifetime makes a "set up once, use for months" automation feel
  heavy. Mitigation: one-step renewal against unchanged evidence. Changing the lifetime is
  not proposed here.
- AWX versions differ in role names and API details. Mitigation: a supported-version
  matrix and a synthetic compatibility suite, as the open change already tasks.
- Catalog files are content from a git repository. Mitigation: parsed at a pinned commit,
  schema-validated, and never trusted past the human review.

## Migration Plan

1. Repository commit and digest recording; catalog parsing; automation resources. No
   upstream effect.
2. Target readiness, the membership page, address-on-approval and the quarantine exit.
   Useful on their own, and they unblock review. The entries of `defects.md` are filed and
   fixed separately and are not part of this plan.
3. Provisioning purpose, verbs and orchestration behind the provisioning permission.
4. Review hand-off, drift reconciliation, retirement.
5. Terraform resources and the worked example, verified on a synthetic controller and
   then as an explicitly requested canary.

Existing hand-built templates and their bindings keep working unchanged; nothing is
adopted automatically. Rollback: withhold the provisioning permission and credential;
owned objects remain valid AWX objects and their approved bindings keep working.

## Non-goals and first-version limits

- No creation or modification of organizations, inventories, hosts, groups, credentials,
  credential types, execution environments, users, teams, notification templates or
  schedules.
- No pushing ServiceRadar devices into AWX inventory.
- Public HTTPS git repositories only, as repositories are today. Private repositories
  need a referenced SCM credential and are deferred.
- No callback content, no workflow job templates, no job slicing, no AAP-only features.
- No secret inputs. A playbook that needs a secret takes it from an AWX credential.
- One inventory, one execution environment and one machine credential per revision.
- No adoption of hand-built templates into ownership in the first version; the open
  change's explicit adoption remains available for its own resource API.
- No automatic approval, renewal or launch, by API, Terraform or schedule.

## Open Decisions for the owner

1. **Home of the primitives.** Implement tasks 2.1 to 2.4 of
   `add-declarative-ansible-provisioning` under that change first (recommended), or fold
   them into this change's delivery.
2. **Hosts absent from AWX inventory.** Report and send the operator to AWX (recommended,
   consistent with the approved "do not push devices" requirement), or open a separate
   proposal for a ServiceRadar-owned inventory that publishes reviewed devices as hosts.
   The second removes the last out-of-product step and reverses an approved requirement.
3. **Where owned objects live.** A dedicated AWX organization for ServiceRadar-owned
   projects and templates (recommended: confines the provisioning principal), or an
   existing organization.
4. **Immutable generations** (recommended) or in-place edits with forced re-review.
5. **Two-person rule.** Leave separation to role assignment (recommended), or refuse
   approval by the principal who provisioned.
6. **Retirement.** Delete retired templates and unused projects (recommended), or keep
   them without role grants.
7. **Approval lifetime.** Keep 24 hours at most with one-step renewal (recommended), or
   propose a longer lifetime for automation bindings in a separate change.
8. **Package source for the worked example.** Let the playbook resolve the release
   (recommended for the first version), or have ServiceRadar prefill URL and digest from
   its mirrored release artifacts so the controller needs no access to the release host.
9. **Variant selection.** Route by the device's known package family and ask when unknown
   (recommended), or always ask.
10. **Inventory sources (Decision 14).** Defer to a second phase (recommended) or include.
11. **First-party pin.** One tested commit per ServiceRadar release (recommended), or
    track the repository's latest tag.

## Not established from the code

- The AWX role names and whether "Job Template Admin" can be withheld from executing, per
  supported AWX version. Reasoned from AWX behaviour, not from this repository.
- Whether AWX accepts a commit hash as the project's revision field with update-on-launch
  off on every supported version, and reports it back as the synced revision in the form
  live preflight compares. A task proves it on the synthetic controller.
- Whether binding review cross-checks the caller's `input_schema` against the live survey.
  The survey could not be found being compared in `A/awx_launch_contract.ex:1075`; this was
  reported by a code survey and is not independently verified.
- Whether a device present in two inventories can hold two linkable memberships. The
  reconciler resolves links through one `metadata["awx"]` entry per device
  (`A/awx_membership_reconciler.ex:120`); the multi-inventory consequence is inferred.
- The cause of the specific symptoms reported from one deployment (proposed rows beside
  quarantined duplicates with no address, one host absent). `defects.md` gives the code
  paths that produce each symptom; no live system was inspected for this proposal.
- The public documentation refers to a `serviceradar-ansible` "agent role"
  (`docs/docs/agent-platform-packages.md:46`); the repository's `main` branch has root
  playbooks and shared task files instead.
