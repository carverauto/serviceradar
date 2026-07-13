# Change: Add attenuated automation callback grants

## Why

ServiceRadar-launched Ansible jobs sometimes need to read ServiceRadar-owned data, beginning with the public SSH user-CA bundle and target-specific principal policy. Passing the logged-in user's ordinary bearer token would expose unrelated authority to AWX, while passing a platform or worker credential could let the job act with more privilege than the user who launched it.

The platform needs a generic automation callback contract whose authority can only contract from the initiating user or explicitly configured service principal. The contract must also survive the asynchronous AWX launch boundary without exposing a reusable credential in run data, surveys, logs, facts, or managed hosts.

## What Changes

- Add opaque short-lived automation callback grants with a permanent issuance-time authorization ceiling and current-state reauthorization on every request.
- Require the logged-in profile to hold both `ansible.runs.launch` and exact RBAC key `devices.remote_access.ssh.ca_bundle.read` before dispatching the first action, `remote_access.ssh_ca.bundle.read`. The new key is administrator-only by default and custom roles must opt in explicitly.
- Bind every integrated grant to one tenant, parent run, local child execution, controller, inventory, template, immutable SCM revision/content hash, exact device/AWX-host target set, target policy/principal mapping, audience, TTL, budget, and idempotency policy.
- Create grants as unusable `pending` records before dispatch, atomically bind the returned controller-local AWX job ID, and activate only after exact launch verification. Ambiguous dispatch, relaunch/copy, mismatch, cancel, or terminal state revokes the grant.
- Deliver the bearer only through a reviewed ephemeral AWX custom credential and a single-resolution authenticated launch envelope. Surveys, ordinary `extra_vars`, inventory variables, facts, artifacts, and managed-host files are forbidden token carriers.
- Add a versioned action registry, canonical bounded HTTPS transport, atomic replay-safe consumption, restricted service-principal ceilings, immutable catalog/template supply-chain binding, and durable secret-free lifecycle audit.

**BREAKING**: Callback-enabled jobs with missing user permissions, mutable/unapproved revisions, ambiguous target bindings, unreviewed AWX credential injection, or an unverified returned AWX job are rejected instead of inheriting worker/platform authority or launching with visible variables.

## Impact

- Affected specs: `automation-callback-grants` (new)
- Affected code: core Ash resources/actions/policies and RBAC catalog/profile management, Ansible launch planning/dispatch, agent command secret envelopes, AWX template/credential binding, web-ng confirmation/audit UX, Helm callback origin/trust configuration, and tests
- Supersession: this bounded child is the sole owner of the callback capability and replaces the draft callback delta in the unmerged program discovery record
- Security boundary: the authorized ServiceRadar dispatcher, AWX controller credential-decryption path, selected execution environment, and reviewed Ansible helper transiently handle the bounded bearer; managed hosts do not
- Hard prerequisite: reconcile/archive the delivered `add-ansible-integration` baseline, then approve and implement `harden-ansible-awx-targeting` so child execution, exact targets, secret references, and callback-action launch gates are canonical before integrated callbacks are enabled
