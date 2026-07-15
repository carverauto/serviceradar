## Context

ServiceRadar launches AWX jobs through an edge-resident AWX WASM plugin so the
control plane never receives the controller API token. The current secure
launch flow validates ServiceRadar-side bindings and policy, then persists an
operation/execution and dispatches `awx.launch_job`. Existing `fetch_template`
and `list_hosts` support is asynchronous and cannot be used as a precondition
before persistence.

The current `AwxTemplateBinding` review metadata retains an
`awx_snapshot_digest`, but not the reviewed canonical AWX snapshot itself. A
digest alone proves neither what fields were reviewed nor how to compare a live
projection. The preflight contract must therefore add immutable, secret-free
review evidence before it can claim complete live-state comparison.

This is not sufficient for a reviewed launch contract. A job template can be
changed in AWX after ServiceRadar reviews it: a project branch, inventory,
credential set, execution environment, survey, or prompt-on-launch flag can
change the work performed. An inventory host can also be renamed, disabled, or
move to a different address after discovery.

## Goals / Non-Goals

- Goals:
  - Verify the live AWX state through the controller's assigned edge agent
    immediately before each mutable launch.
  - Prevent a drifted, unavailable, malformed, or unauthorized request from
    creating a run/execution or invoking an AWX mutation.
  - Preserve a durable, secret-free evidence trail for the exact reviewed and
    live state used for a launch.
  - Ensure a user's ServiceRadar authorization bounds the controller token's
    effective use.
- Non-Goals:
  - Do not forward the user's browser token, an API key, or a CA private key to
    AWX or to a playbook.
  - Do not make direct AWX launches a supported ServiceRadar workflow.
  - Do not mutate or auto-repair a drifted AWX template, project, inventory,
    credential, or execution environment.
  - Do not enable the demo callback policy merely by merging this proposal.

## Decisions

### Decision: Use one read-only compound preflight verb

The AWX plugin will expose `awx.fetch_launch_preflight`. Its request is created
only by the ServiceRadar secure-launch service and carries non-secret reviewed
selectors: controller, template, project, inventory, credential IDs,
execution-environment ID, and already-authorized target host tuples. `AwxClient`
mints the controller broker grant internally; the domain preflight request never
carries a grant. The plugin performs only AWX `GET` requests against paths
already bound by those selectors and cross-checks every returned ID. It SHALL
NOT derive arbitrary dependent-resource paths from an initial template response.
It returns a typed, bounded, redacted projection:

- template identity, project, inventory, playbook, job settings, all
  prompt-on-launch flags, associated credential IDs, execution-environment ID,
  and modification/version fields;
- canonical survey specification and its SHA-256 digest;
- project identity, SCM type/URL/branch, last resolved revision, clean status,
  and modification/version fields;
- inventory identity and each selected host's ID, enabled state, normalized
  name, normalized `ansible_host`/address, and a digest of non-secret identity
  variables;
- associated credential metadata limited to ID, name, and type, plus execution
  environment metadata limited to ID, name, and image digest/reference.

The plugin never returns credential secret material, controller headers, raw
AWX error bodies, or unbounded host variables. It fetches the job template both
before and after dependent resources and fails if its identity/version changes
during the read. This reduces the time-of-check window. AWX does not provide a
portable conditional-launch primitive, so production relies additionally on
the AWX runner's inability to edit reviewed resources; an external AWX
administrator can still make a change after any read and must use the reviewed
change-management process.

### Decision: Persist immutable reviewed evidence, then compare complete state

Each approved binding version will carry immutable, secret-free
`reviewed_launch_snapshot` and `reviewed_launch_snapshot_digest` attributes.
The snapshot uses the versioned `serviceradar.awx_launch_contract.v1` schema,
string-only normalized keys, no floats, and canonical JSON plus its SHA-256
digest. It will be validated with `CallbackGrants.CanonicalJSON.digest/1` and
cross-checked against the existing `review_metadata.awx_snapshot_digest` during
the migration period. Existing digest-only bindings are not launchable until an
authorized reviewer creates a complete review snapshot.

A launch preflight requires exact equality between that reviewed snapshot and
the live projection for:

- template, project, and inventory IDs; project SCM type, URL, branch, and
  resolved revision; template playbook, job type, timeout, forks, and
  allow-simultaneous settings;
- fixed credential IDs/types, execution-environment ID and approved immutable
  image digest/reference;
- every launch prompt flag, including inventory, credentials, execution
  environment, variables, limit, SCM branch, job type, tags, verbosity, and
  diff mode;
- the canonical survey digest and its exact restricted dispatch-marker fields;
- the controller and inventory identity for the reviewed template.

Selected hosts do not live in the binding because every launch has a dynamic
target set. Immediately before dispatch, ServiceRadar builds an expected-target
snapshot from each exact current `AwxHostMembership` tuple: membership ID,
source generation/fingerprint, controller/inventory/AWX-host IDs, canonical
device UID, host name, normalized `ansible_host`, and enabled state. The live
result is compared only to that selected set; a host, address, or inventory
returned by AWX can never broaden the target authority.

The comparison is deny-by-default: unknown fields, duplicate IDs, a missing
associated resource, non-canonical JSON, or an unsupported prompt value are
drift. The preflight response is not an authority to broaden the binding.

### Decision: Await durable commands before creating a mutable execution

`LiveAwxLaunchPreflight` dispatches the read-only command through the ordinary
agent command bus and waits for terminal `AgentCommand` rows using the database
as the authority. PubSub may wake the waiter but is never the source of truth.
The wait is bounded and cancellation-safe. Timeout, agent disconnect, malformed
result, or an AWX read error returns an operator-safe preflight failure.

No `AutomationSecureExecutionOperation`, child execution, `PlaybookRun`, or
`awx.launch_job` command is created before a successful comparison. The
read-only command rows remain available for audit but carry only redacted
payloads. A new secret-free `AutomationAwxLaunchPreflightEvidence` resource,
with no operation/execution foreign key, records the command ID, controller,
agent, partition, binding/version/approval IDs, reviewed/request/target/
controller-security/live/result digests, verification timestamp, and expiry.
The immutable launch snapshot copies this evidence ID and digests after the
second authorization read.

### Decision: Re-authorize and bind immutable evidence immediately before launch

After a successful live comparison, ServiceRadar re-reads the actor, role
membership, holds, callback binding, controller-security state, and every target
membership. It requires the same authorization and policy conditions that were
true before the read. It then writes an immutable launch snapshot containing the
binding revision, canonical reviewed digest, live preflight digest, command/
result digests, and preflight-evidence ID. The existing launcher may dispatch
`awx.launch_job` only from that snapshot.

This protects against a user losing a permission, a hold appearing, or a
binding/target changing while an edge read is in flight. User-supplied launch
parameters cannot replace template, inventory, credential, project, or
execution-environment choices.

### Decision: Make the controller principal least-privilege and auditable

The AWX service account used by ServiceRadar is a machine principal, not a
browser credential. Its AWX roles must be limited to reading the preflight
resources and executing approved templates with the reviewed inventory and
credential set; it must not edit templates, projects, inventories, credentials,
or execution environments. ServiceRadar RBAC remains the user authorization
point: a caller must have the launch permission and any required callback/CA
permission before a preflight is dispatched and again before launch.

The operator runbook will make clear that direct AWX execution must be
restricted to the ServiceRadar runner/team, otherwise an AWX user can bypass
ServiceRadar's audit and policy model.

### Decision: Surface drift as a review event, never as an implicit update

Drift generates a normalized reason such as `template_project_drift`,
`credential_set_drift`, `survey_contract_drift`, or `target_membership_drift`.
The user sees a safe message and a link to the binding review surface. Only an
authorized reviewer can create a new reviewed binding snapshot; ServiceRadar
does not silently absorb live values.

## Risks / Trade-offs

| Risk | Mitigation |
| --- | --- |
| The extra AWX reads add launch latency. | One bounded compound request, not a sequence of UI round trips; the request is made only for a mutable launch. |
| An edge agent disconnects mid-preflight. | Fail closed before an execution exists; the operator retries after connectivity recovers. |
| AWX changes during dependent reads. | Compare the template before and after reads and fail on version change; constrain the runner role so it cannot make the change. |
| An external AWX administrator changes a template after preflight. | Immediate launch after double-read, immutable evidence, least-privilege runner, and a documented change-management requirement; no false claim of cross-system atomicity. |
| Raw AWX payloads might include secrets or noisy data. | Typed projection, bounded fields, canonical digest, and redaction at the plugin boundary. |

## Migration Plan

1. Ship the read-only preflight verb and comparison path while mutable callback
   policy remains disabled.
2. Add fixture and integration coverage for matching state, each drift family,
   timeout, malformed response, authorization loss, and no-preflight/no-launch
   regressions.
3. Configure the AWX runner account and approved template bindings; synchronize
   inventories only after the reviewed project/template state is current.
4. Enable a narrowly scoped demo callback policy only after a successful
   ServiceRadar-initiated canary proves the preflight evidence and run outcome.
5. Roll back by disabling the callback policy. The preflight remains fail-closed
   and no credential or template mutation needs to be reversed.

## Open Questions

- Does the deployed AWX version expose stable response version/ETag data that
  can supplement `modified` timestamps in the double-read check? The plugin
  must treat absence as a reason to rely on canonical payload digest, not as a
  reason to skip the check.
