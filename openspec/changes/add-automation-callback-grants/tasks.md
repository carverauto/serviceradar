## 1. Security contract and data model

- [ ] 1.1 Approve this child proposal after the Ansible baseline is reconciled and `harden-ansible-awx-targeting` defines collision-safe child execution, exact targets, secret references, and callback-action permission gates.
- [ ] 1.2 Add the versioned action registry and register only `remote_access.ssh_ca.bundle.read` as bounded read-only internal target configuration with no secret material.
- [ ] 1.3 Add Ash grant/use/audit resources with hashed opaque bearer, pending/active/revoked/expired/consumed state, immutable issuance/target/policy/revision snapshot, audience, TTL, budget, idempotency, and cleanup.
- [ ] 1.4 Add `devices.remote_access.ssh.ca_bundle.read` to the RBAC catalog and profile/role UI/API, administrator-only by default, absent from viewer/operator defaults, and explicitly assignable to custom roles; service principals require it plus `ansible.runs.launch`.

## 2. Authorization and AWX binding

- [ ] 2.1 Require `ansible.runs.launch`, `devices.remote_access.ssh.ca_bundle.read`, exact target policy, and approval before run creation/dispatch; apply the same intersection to interactive and service-principal launches.
- [ ] 2.2 Create child/snapshot/pending grant before dispatch; atomically verify/bind the returned controller-local job, exact base-plus-ephemeral credential set, and complete authenticated job-host-summary set before activation.
- [ ] 2.3 Reauthorize issuance ceiling plus current principal/run/job/target/policy/approval/action state on activation and every use.
- [ ] 2.4 Revoke on definitive/ambiguous dispatch, mismatch, cancel, relaunch/copy, terminal state, permission loss, expiry, and cleanup; immediately attempt AWX child cancellation and persist `cancel_failed`/orphan-risk state when cancellation cannot be confirmed.
- [ ] 2.5 Add all-or-nothing target-policy retrieval and target-keyed principal mapping with cross-target substitution denial.
- [x] 2.6 Route ephemeral credential create/fetch/delete through an explicit callback controller credential, route launch/job lifecycle through execution and catalog/inventory through sync, allow reviewed callback=execution, and document a dedicated empty callback organization with no Credential Admin over production credentials.

## 3. Secret delivery and transport

- [ ] 3.1 Add a single-resolution encrypted launch envelope with authenticated binding to tenant/command/child/controller/inventory/template/dispatch agent/expiry.
- [ ] 3.2 Add and validate an ephemeral reviewed AWX custom credential environment/header injector; reject survey/ordinary-variable fallback and require AWX's non-injectable system `JOB_ID` in the exact request/response contract.
- [ ] 3.3 Add the reusable Ansible callback helper contract with canonical HTTPS, CA/hostname verification, no redirects/credential-forwarding proxies, bounded time/size/method, schema validation, no_log, and sanitized retry statuses.
- [ ] 3.4 Restrict execution-environment callback egress to the server-declared destination and declared job dependencies.
- [x] 3.5 Split runtime custody so only web receives bearer HMAC/origin, core receives enabled-only envelope/contract/policy material plus secret-free internal continuation adapters, gateway receives none, and disabled external-Secret upgrades project no callback keys.

## 4. Replay, supply chain, audit, and UX

- [ ] 4.1 Implement atomic one-read idempotency, same-key byte-identical lost-response recovery, concurrency denial, and separate authentication abuse throttling.
- [ ] 4.2 Pin reviewed catalog metadata, SCM revision/content hash, and project/template/inventory/credential binding; verify the accepted AWX job revision and require reapproval on drift.
- [ ] 4.3 Add durable secret-free lifecycle/use/misuse audit and fail closed when successful consume/audit cannot commit.
- [ ] 4.4 Add confirmation/profile UX showing `ansible.runs.launch`, `devices.remote_access.ssh.ca_bundle.read`, named action, targets, policy/approval, revision, TTL, and budget; add authorized grant inspection/revocation without token/hash exposure.

## 5. Verification and rollout

- [ ] 5.1 Test missing-either-permission, SystemActor/confused deputy, later promotion, permission/tenant/approval contraction, target drift, revision mismatch, and service-principal ceilings.
- [ ] 5.2 Test pending race, incomplete host summaries, ambiguous dispatch, returned-job/credential/runtime-`JOB_ID` mismatch, cancel, relaunch/copy, concurrent use, lost response, changed-payload replay, expiry, and revocation.
- [ ] 5.3 Test ServiceRadar/AWX job API, stdout/events, facts, artifacts, relaunch/copy, analytics, support bundles, failure logs, backups, and managed hosts for bearer non-disclosure.
- [ ] 5.4 Test TLS/hostname/redirect/proxy/content-type/schema/size/time bounds, response-fingerprint semantics, egress restriction, audit failure, and misuse alerts.
- [ ] 5.5 Enable only for the reviewed public CA-bundle action and pass a deployed canary callback proof before fleet use.
