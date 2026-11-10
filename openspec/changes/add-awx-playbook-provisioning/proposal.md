# Change: Provision the AWX project and job templates a reviewed playbook needs

## Why

ServiceRadar can register an AWX controller and a git playbook repository, mirror AWX
inventory, review exact host memberships and job-template bindings, and prepare and launch
operations. It cannot create the AWX objects those steps depend on. The API contract says
so: "This foundation does **not** create upstream AWX organizations, projects,
inventories, inventory sources, credentials, or job templates. Those objects must already
exist." (`docs/docs/ansible-provisioning-api.md:8`). In code the only AWX mutations are job
launch, job cancel and the ephemeral callback credential
(`go/cmd/wasm-plugins/awx/main.go:398`, `:1087`, `:1819`); there is no create, update or
delete for projects or job templates, and no PATCH or PUT helper at all.

The consequence, met while trying to use the integration for a routine task (upgrade the
agent package on a set of hosts with the official playbook from the public
`carverauto/serviceradar-ansible` repository): the playbook existed, the hosts were in AWX
inventory, and there was no job template. ServiceRadar could not make one. An operator has
to leave the product, build a project and a template by hand in AWX with exactly the
prompt flags, survey fields and pinned revision the hardened launch contract demands
(`elixir/serviceradar_core/lib/serviceradar/automation/ansible/awx_launch_contract.ex:630`,
`:640`; `dispatch_marker_contract.ex:22`), then come back and review a binding. A registered
repository contributes nothing to that work: sync records no commit
(`playbook_repository.ex:128`), nothing links a repository to an AWX project, and the
binding's `content_sha256` and `input_schema` are typed in by the caller
(`awx_binding_review.ex:257`, `:273`).

A second gap sits beside it. A device that exists in ServiceRadar is frequently not
launchable, and the product does not say why. Memberships sit in `proposed` because
approval is API-only and has no page; `quarantined` rows never leave that state
(`awx_membership_reconciler.ex:433`, `:462`); a membership with no address can be approved
and then fails live preflight (`live_awx_launch_preflight.ex:414`); a host with no usable
anchor is skipped by the collector without a trace
(`go/cmd/wasm-plugins/awx/main.go:3856`). Part of that is missing capability and part is
defect. They are separated: `defects.md` lists the defects with pointers; the capability is
specified here.

## What Changes

- **Automations.** A new ServiceRadar resource describes one launchable playbook: the
  registered repository, an immutable commit, a playbook path per variant and the content digest, a
  typed non-secret input schema, and references to the AWX inventory, execution
  environment and machine credential it uses. Each revision is immutable.
- **Repositories resolve to commits.** Repository sync records the resolved commit and a
  digest per playbook file, and parses first-party catalog files
  (`serviceradar.automation.catalog/v1`, the schema the public repository already uses).
- **Typed provisioning of the AWX project and job template.** For an automation revision
  ServiceRadar uses one AWX project per repository and commit, pinned with
  update-on-launch off, and creates one job template per variant and offered run mode
  whose prompt flags and survey are exactly what the hardened launch contract requires:
  the two dispatch-marker fields plus the automation's typed inputs.
  This uses the typed, brokered provisioning contract of
  `add-declarative-ansible-provisioning` and does not restate it.
- **Immutable generations instead of in-place edits.** A new revision provisions new job
  templates and references the project for its commit, creating one only for a new
  commit. An owned project or template is never edited. Drift is
  detected and reported; ServiceRadar never repairs a bound object and never absorbs live
  values.
- **Owned versus referenced, stated per object type.** Owned: projects, job templates,
  their surveys, and the two kinds of role grant the execution principal needs on them:
  Execute on every owned template and Read on each owned project.
  Referenced only: organizations, inventories, hosts, execution environments, machine and
  SCM credentials, instance groups.
- **A provisioning principal that cannot launch and an execution principal that cannot
  edit.** A fourth controller credential purpose with its own verbs and broker policy.
- **Provisioning ends in a prepared review, never in an approval.** When the objects
  exist, ServiceRadar reads them back with the execution principal and opens the existing
  binding review with the digest and input schema taken from the automation revision
  instead of from the caller. A human principal approves through the existing gate.
  Nothing becomes launchable otherwise.
- **Target readiness.** For a device and a controller, one answer: launchable, or the
  specific reason it is not and the action that resolves it. Membership review gets a page.
  Quarantine gets a reviewed exit that returns a row to `proposed`, never to `approved`.
- **A first-party catalog entry as the worked example**: "Install or upgrade the
  ServiceRadar agent package", end to end.
- **API, Terraform and UI surface; permissions; audit events** for all of the above.
- **Optional, second phase:** inventory sources backed by a file in the same pinned
  project. Not required for the workflow above.

No **BREAKING** change. Four approved statements are relaxed and each is named in
`design.md` under "Approved statements this change relaxes".

## Why a new change and not more requirements in `add-declarative-ansible-provisioning`

That change is open, partly delivered, and already owns the requirement "Typed AWX
provisioning through the broker" with tasks 2.1 to 2.6 unticked. This proposal builds on
it and is kept separate for four reasons:

1. **Different layer.** The open change specifies primitives: typed commands, exact
   request-body custody, ownership records, ambiguous-create recovery, Terraform
   semantics. This change specifies a product workflow on top of them: what an automation
   is, which objects it produces, how its survey is derived, how drift is handled, how the
   result reaches review, what the operator sees. None of the open change's requirements
   is copied or modified.
2. **Different approval.** This change relaxes non-goals written into three other open
   changes and one settings-UI requirement. That deserves its own decision rather than
   arriving inside a change whose scope was already approved.
3. **Different acceptance.** The open change's acceptance is "bootstrap and adopt through
   the public API and Terraform". This one's is "register repository, pick playbook,
   review, launch, without the AWX UI", plus target readiness.
4. **Repository convention.** Adding requirements to a capability owned by another open
   change, with the ownership stated, is established practice here
   (`fix-integration-plugin-credential-delivery` adds to `credential-management`).

The dependency is explicit: tasks 2.1 to 2.4 of `add-declarative-ansible-provisioning`
must land first or be implemented under this change. Which one is an owner decision
(`design.md`, Open Decisions).

## Related active changes

- `add-declarative-ansible-provisioning` owns the `ansible-provisioning` capability, the
  typed brokered provisioning contract, ownership and ambiguous-mutation recovery,
  idempotency and concurrency conventions, the `ansible.controllers.provision` permission
  and the Terraform provider. This change adds requirements to that capability.
- `harden-ansible-awx-targeting` owns the `ansible-awx-targeting` capability: memberships,
  launch planning, purpose-split credentials, per-verb endpoint mapping, dispatch markers.
  This change adds two requirements there and consumes the rest unchanged.
- `harden-awx-live-launch-preflight` owns live preflight and the rule that the execution
  principal has no edit rights. Unchanged, and relied on.
- `remove-legacy-ansible-ui` owns the Ansible pages and the statement that Ansible settings
  expose controller and repository management only; see `design.md`.
- `refactor-unified-credential-management` owns credential custody. The new credential
  purpose follows it: declared by the AWX package, restrictive foreign key, usage
  inventory.
- `add-automation-callback-grants` owns callbacks. Automations in this change are
  non-callback; callback bindings stay with that change.
- `publish-ssh-ca-ansible-enrollment` and `publish-windows-qemu-guest-agent-ansible` leave
  AWX import to "the later ServiceRadar/AWX binding change". This is that change for
  non-callback content.
- `add-agent-updater-self-update` links to the worked example as one remedy for hosts that
  need a one-time agent package upgrade.

## Impact

- Affected specs: `ansible-provisioning` and `ansible-awx-targeting` (added requirements;
  both capabilities are owned by open changes), `build-web-ui`.
- Affected code: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/`
  (repository sync, new automation and managed-object resources, provisioning
  orchestration, binding review inputs, membership reconciliation and approval, readiness),
  `go/cmd/wasm-plugins/awx/` (new typed verbs, manifest purposes),
  `ServiceRadar.Automation.Ansible.AwxClient` verb and endpoint maps, the RBAC catalog,
  web-ng API controllers, OpenAPI, Ansible settings and device panels,
  `go/pkg/terraformprovider/`, and the Ansible, provisioning API, Terraform and
  declarative-environment documentation.
- Out of scope: creating AWX organizations, inventories, hosts, credentials or execution
  environments; private git repositories; callback content; schedules; AAP-specific
  features. See `design.md`, "Non-goals and first-version limits".
