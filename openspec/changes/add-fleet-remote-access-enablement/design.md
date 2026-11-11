## Context

The normative text is in the spec deltas. This document gives the evidence, the reasons
and the choices. Where a rule is stated in a spec it is referenced here, not restated.

`E/` is `elixir/serviceradar_core/lib/serviceradar/edge/`. `C/` is
`elixir/serviceradar_core/lib/serviceradar/credentials/`. `W/` is `elixir/web-ng/`.
`R/` is the public content repository `carverauto/serviceradar-ansible` at `origin/main`
(commit `fa40fdc`), read with `git show`; it was not modified.

### What exists today (read from code)

| Fact | Source |
| --- | --- |
| The certificate policy is read once at boot from `SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_JSON` or `..._FILE` and placed in app env `:remote_access_ssh_certificate_policy`. | `W/config/runtime.exs:791-805`, `:954-957` |
| The chart mounts that file from an operator-owned Secret and validates only that a Secret name and key are given. | `helm/serviceradar/templates/_helpers.tpl:832-851` |
| Per device, the policy is the top-level document merged with one `targets` entry; the entry is found by trying UID, then hostname, then IP. A top-level `accounts` list applies to every device. | `E/remote_access_sessions.ex:1098-1125` |
| The console's recourse text tells the operator to "grant this device a certificate-policy account". | `W/assets/component/src/RemoteAccessSSHConsole.jsx:21-26` |
| Principals are opaque strings matching `^srp_v1_[A-Za-z0-9_-]{20,96}$`; they are selected by matching identity-provider claims (groups, email, email domain, claim) against hand-written mappings. Nothing generates one. | `E/remote_access_ssh_certificate_policy.ex:23`; `E/remote_access_ssh_principal_mapper.ex:17-83` |
| Certificate issuance requires an OIDC or SAML session. | `E/remote_access_ssh_identity_issuer.ex:15`, `:153-161` |
| The callback response policy is a server-owned file, at most 100 targets per policy, selected by controller, inventory, AWX host and canonical device UID; it is a behaviour with one file-backed provider. | `.../automation/ansible/file_callback_response_policy_provider.ex:1-23`, `:274`; chart requirement at `helm/serviceradar/templates/_helpers.tpl:822-828` |
| The agent verifies host keys against its own known-hosts file. A session can carry one approved target and fingerprint, which comes from browser-supplied session metadata. | `go/pkg/agent/push_loop.go:478-498`; `go/pkg/agent/remoteaccess/ssh_host_key.go:107-128`; `E/remote_access_broker.ex:1079`; `W/assets/component/src/RemoteAccessSSHConsole.jsx:1001` |
| A host-key resource already exists with device UID, key type, fingerprint, public key, status (`pending`, `trusted`, `conflict`, `rotated`, `revoked`, `rejected`), source, rotation linkage, version history and the permission `settings.remote_access_host_keys.manage`. Documentation states that verification does not consult it. | `E/remote_access_host_key.ex:19`, `:164-294`; `E/remote_access_host_keys.ex:61-137`; `docs/docs/remote-access.md:683-687` |
| An SSH connection error is returned from the agent as the library's error. | `go/pkg/agent/remoteaccess/ssh.go:311-315` |
| Credential rules carry provider, auth method, purpose, target query, scope type (`agent`, `gateway`, `partition`) and value, a mandatory secret reference, allowed ports, an SSH host-key policy, priority, enabled, metadata, version history, a preview action and a guarded destroy. | `C/network_credential_rule.ex:74-83`, `:110-132`, `:162-294` |
| The actor-use policy for a rule (principals, roles, groups; deny by default) lives in rule metadata. | `C/credential_use_policy.ex:1-60` |
| The Terraform provider already has a `network_credential_rule` resource. | `go/pkg/terraformprovider/definitions.go:39` |
| A merge reassigns device references table by table, including virtualization hosts and guests and AWX memberships; remote-access host keys are not among them. | `.../inventory/identity/reassignments.ex:23-306` |
| A console request resolves the target through the stored relationship, then looks for a rule by the host device's agent, gateway and partition, then by all enabled provider rules. Every per-rule check is combined with `and`, so any failure yields `:no_console_credential_rule`. | `E/proxmox_console_sessions.ex:283-350`, `:1045-1053` |
| "Rule targets device" is decided by running the rule preview with a 5,000-row sample and looking for the host device's UID in it. | `E/proxmox_console_sessions.ex:444-464` |
| The preview drops a row whose agent differs from an agent-scoped rule's agent. | `C/network_credential_rule_preview.ex:106-113` |
| A console rule must carry the target's integration and controller. | `E/proxmox_console_sessions.ex:535-543` |
| Guests and hosts are stored with integration, controller, native cluster, host reference and device UID. | `.../inventory/virtualization_guest.ex:124-152`; `.../inventory/virtualization_host.ex:117-145` |
| The only product reference to `metadata.proxmox_cluster` is a read fallback. | `.../plugins/plugin_input_payload_builder.ex:186-191` |
| Console documentation asks for "the PVE permissions needed" without naming them. | `docs/docs/proxmox.md:385` |

Read from `R/` (by a survey of that repository; line numbers are the survey's):

| Fact | Source |
| --- | --- |
| `fleet_ssh_enroll`: Debian 12 only; creates or converges one locked account; one principal list for all hosts; drop-in `60-serviceradar-user-ca.conf`, CA at `/etc/ssh/serviceradar_user_ca.pub`, principals at `/etc/ssh/auth_principals/%u`; no rollback, no removal, no state file. | `R/roles/fleet_ssh_enroll/tasks/validate.yml:2-9`, `enroll.yml:2-66`, `defaults/main.yml:47-49` |
| `remote_access_ssh_ca`: Ubuntu 22.04/24.04, Debian 12, Rocky 9 with systemd; never creates accounts; fixed paths (`10-serviceradar-remote-access.conf`, `/etc/ssh/serviceradar/current/...`); transactional stage, verify, commit with timed rollback; refuses any unmanaged `TrustedUserCAKeys` or `AuthorizedPrincipalsFile` and any running `ssh.socket`. | `R/roles/remote_access_ssh_ca/tasks/preflight.yml:2-22`, `:108-122`, `:274-286`, `:359-372`; `validate_policy.yml:82-104`; `tasks/main.yml:2-14` |
| Hypervisors and control-plane hosts are excluded only by a constant (`sr_ra_target_risk == 'standard'`); nothing inspects the host. | `R/roles/remote_access_ssh_ca/tasks/main.yml:9`; `defaults/main.yml:42-43` |
| Neither role reports results or host keys to ServiceRadar. | absence, by search |
| The integrated path is held off by `production_import_ready: false`. | `R/catalog/remote-access-ssh-ca.yml:7-12` |
| Only the newer role's direct preflight has a behavioural test. | `R/.github/workflows/quality.yml:91-97` |

The product documentation describes a third layout: the newer role's directory with a
drop-in named `60-serviceradar-user-ca.conf` (`docs/docs/remote-access.md:316-366`).

### Constraints inherited from approved work

- Device and integration credentials live in the unified credential model; no
  consumer-local secret store, no Helm-only behaviour (`AGENTS.md`, Hard Rules).
- AWX hosts are targeted only by `(controller_id, inventory_id, awx_host_id)` linked to
  one canonical device; ServiceRadar does not write AWX hosts or host variables;
  per-host values reach a job only through the callback response
  (`harden-ansible-awx-targeting`, `add-automation-callback-grants`).
- Only one callback action exists, the read-only bundle read; a mutating or signing
  callback needs its own security proposal (`add-automation-callback-grants`).
- Single deployment; no multitenancy feature.
- LiveView: no queries in disconnected mount; streams above 100 rows.

## Goals / Non-Goals

- Goals: a grant, an enrollment and a readiness answer for every device, each derived
  from stored state and each available through UI and API; one layout; no per-host
  hand work; no per-agent trust clicks; Proxmox console rules that match what the
  operator means and say why they do not.
- Non-Goals:
  - Changing how the CA signs or hardening signer custody beyond offering a built-in CA.
  - Managing sudo, PAM, directory services or root access on targets.
  - Automated enrollment of hosts without systemd, operating systems outside the
    public content's declared list, network operating systems and Windows. These use
    the manual channel.
  - Merging ServiceRadar's CA into a host that already trusts another user CA.
  - Automatically starting enrollment. A principal always launches it.
  - Central host-key trust for the Proxmox SSH host console, which keeps the policy of
    `harden-proxmox-console-credential-custody`.
  - A console rule that covers a PVE host but not its guests.
  - Fixing the items in `defects.md`; they are independent.

## Decisions

### Decision 1: a grant is a credential rule, and the CA is the credential it references (recommended)

A certificate grant has the shape of a credential rule: target query, edge scope,
priority, enabled flag, actor-use policy, preview, version history, guarded deletion,
admin API, Terraform resource. Reused as is: the `network_credential_rules` table and
resource, `TargetQuery` validation, the scope columns, `CredentialUsePolicy`, the
preview UI, paper-trail history, `settings.credentials.manage`, the credential rule
admin API and the `network_credential_rule` Terraform resource. Added: a typed
`ssh_certificate` block in rule metadata (accounts with mode, lifetime,
`allow_elevated_targets`) with its own validation module, the same way the actor-use
policy already lives in metadata; an exact single-device membership test beside the
sampled preview; and a credential kind `ssh_user_ca`.

A rule must reference a secret (`C/network_credential_rule.ex:237-239`). The honest
referent is the CA: it is the credential ServiceRadar presents to hosts. Making it a
credential record gives it the inventory, usage surface, rotation state and guarded
deletion every other credential has, and gives enrollment a stored list of CA keys to
distribute.

Rule selection differs from secret selection in one way. For a secret, the first
matching rule wins. For access, several rules may list different accounts and admit
different people for the same device, so the first rule that satisfies all of device,
scope, account and actor wins (spec "Deterministic rule selection"). The ordering is
the existing one (priority, then creation time).

Alternative rejected: a dedicated `remote_access_ssh_access_rules` table. It would
copy every column and need its own API, Terraform resource, preview, history and
deletion guard. Alternative rejected: keep the JSON document and add an editor. It
keeps hostname keys, has no scope or actor model and cannot be previewed.

### Decision 2: one principal per device account (recommended)

The principal's job is to say "this certificate may log in as this account on this
host". Tying it to the device account (spec "Principals are generated per device
account") has three consequences that remove most of today's hand work:

- Who may use an account is decided only at issuance. Adding or removing a person or a
  group never touches a host.
- A host's files change only when its set of accounts changes or a principal is
  rotated. Enrollment and granting are decoupled.
- A certificate is useless on any other host or account.

Alternative rejected: a principal per rule or per group, as today. Every membership
change would rewrite host files across the fleet, and a certificate would be valid on
every host the rule covers. Alternative rejected: deriving the principal from the
device UID. It would not be rotatable and would not survive a merge.

### Decision 3: issuance requires a verified device account

A certificate is issued only when the device account's readiness state is `verified`
(spec "Per-device-account readiness state"). This is what turns a raw handshake
failure into a statement made before Connect. Anyone who may open an SSH session to the
device may request a readiness check, so a stale state costs one click, not an
administrator. The gate cannot apply where the routing agent predates the probe, or an
upgrade of the control plane would cut off working access; the spec carries that one
exception.

### Decision 4: one bundle, one layout, three channels; the newer role survives

The bundle (spec "The enrollment bundle is the only source of per-host enrollment
values") is a projection of stored state. The surviving role is
`remote_access_ssh_ca`: it is transactional, covers four platform releases and already
has the integrated contract. `fleet_ssh_enroll` is removed. The surviving layout is
that role's. The documentation's third layout is corrected to it.

What the role must gain is in the `ansible-remote-access-enrollment` delta: adoption
of the two earlier layouts inside its transaction, account mode `managed`, risk class
`elevated`, stock-configuration support (Ubuntu 24.04 ships socket-activated sshd by
default, which the current preflight refuses; inference from the preflight condition,
to be confirmed by the test matrix), structured results with host public keys, and a
direct-mode inventory plugin.

Channels (spec "Enrollment channels"):

- `direct` needs only Ansible and an API token. It is the channel every OSS user has.
- `integrated` is the AWX path already designed by the callback and targeting changes.
  This change replaces the file-backed response-policy provider with one that reads
  stored bundles; the grant still binds an immutable snapshot and hash, so that
  change's binding requirement holds. Fleet enrollments are split into child jobs
  within the existing per-child limit instead of raising it.
- `manual` shows the bundle values for one device with the exact files to write. It is
  the answer for unsupported platforms and for a single host.

Results: the integrated channel reads them from host-scoped job events, which the
launch boundary already scopes to controller, child and target; the direct channel
posts them with a token. No callback action is added.

Alternative rejected: ServiceRadar writing AWX host variables. It contradicts an
approved boundary and makes inventory a second source of truth. Alternative rejected:
the agent enrolling its own host. It covers only hosts that run an agent and gives a
monitoring agent the right to change sshd.

### Decision 5: accounts are named by the rule, in mode `existing` or `managed`

The product never defaults an account name. `existing` suits deployments with a
directory or established admin accounts. `managed` creates a dedicated locked account
so that a deployment with nothing can still be enrolled in one pass. Neither mode
grants privileges; what the account may do on the host remains the operator's
decision. Attribution does not depend on the Unix account: the certificate key ID and
the session audit name the person.

### Decision 6: hypervisors by explicit opt-in; control-plane nodes by exclusion

A hypervisor is identifiable from stored data (a device with a virtualization host
record), so it gets a class, `elevated`, that a rule must opt into
(spec "Supported targets and explicit exclusions"). This is the "separate policy" that
`publish-ssh-ca-ansible-enrollment` left open. Nodes that host the deployment's own
control plane are not identifiable from product data today, so they are handled by an
administrator-set exclusion until an inventory signal exists.

### Decision 7: readiness is verified by a certificate-authenticated probe

The probe (spec "Readiness probe") authenticates and disconnects. It needs no right on
the host beyond what an issued certificate already has, and reads nothing. Its
certificate is system-issued, lives at most 60 seconds, carries a forced no-op command
and no permit extensions, and the agent will not open a channel on it; any one of these
would prevent interactive use. The SSO requirement governs user certificates and does
not apply to it.

A rejection cannot say whether the CA is untrusted, the account is missing or the
principal is absent: sshd answers all three the same way (inference from the protocol;
not tested here). The state model therefore uses history: rejection after a verified
state is `drifted`; rejection without one leaves `not_enrolled`.

### Decision 8: the existing host-key store becomes the trust source

The resource exists with the right lifecycle; what is missing is that verification
consults it. The control plane delivers the device's trusted keys in the session
instruction, which is already authenticated end to end, and the agent pins to them
(spec "Host keys are trusted centrally by device identity"). Lookup is by device UID,
which removes today's rule that trusting a hostname does not cover the same host by
address.

The first key comes from the enrollment result. Its strength is that of the
controller's connection to the host during enrollment, which is the same connection
that installed the CA trust; the probe then confirms the same key from the agent's
vantage point. A changed key is never accepted on observation. Planned re-keying is an
explicit, time-bounded, bulk authorization (spec "Authorized host-key rotation").

Alternative rejected: distributing a known-hosts file to every agent. It copies trust
to agents that never need it and makes revocation a fleet operation. Alternative
rejected: trust on first use per agent. It is today's behaviour.

### Decision 9: certificate mode keeps SSO by default; local identity is an opt-in runtime setting

A deployment with no identity provider otherwise gets no certificate mode at all,
which fails the bar. The setting is explicit, audited and off by default
(spec "Identity required for certificate mode"). Whether local accounts have a second
factor was not established; see "Not established from the code".

### Decision 10: console rule coverage uses the stored relationship and an exact test

The resolver already finds the guest's host, integration and controller from stored
rows. Coverage (spec "Console rules cover targets through the stored virtualization
relationship") reuses that and replaces the sampled preview with the exact
single-device test of Decision 1. Matching the requested device or its owning host
keeps every rule that works today working, and adds rules for a single guest.

Scope (spec "Console rule scope follows who reaches the PVE API") is evaluated against
the agent holding the controller's active assignment, which the code already resolves
after it picks the executing agent (`E/proxmox_console_sessions.ex:545-575`). The host
device's owning agent stops being an input.

Denial reasons come from evaluating every candidate rule to its first failing check and
reporting the nearest miss, with rule detail visible only to those who manage
credentials.

The privilege set is documented and verified through the PVE API. The privileges named
in the documentation will be the console privileges Proxmox defines for nodes and for
guests; their exact names and whether a node console is available to an API token are
to be confirmed against a test cluster before the documentation is written (see "Not
established from the code").

### Decision 11: the file-based policy is imported once

Import rules are in spec "One-time import of the file-based policy". Hostname and IP
keys are resolved to devices at import time; an ambiguous key yields a disabled rule,
never a broader grant. Principals in the old policy become legacy principals so that
hosts enrolled by hand keep working until their next enrollment replaces them with
generated ones; the probe, not the import, decides whether each is actually present.

Chart: the release that ships the import keeps `remoteAccess.sshCertificatePolicy`
solely to feed it and marks it deprecated. The next release removes the value, its
helper validation and its mount, and refuses to render while the value is still set,
with a message naming the Settings page where the imported rules are. The
response-policy Secret (`automationCallbacks.responsePolicy`) is removed in the same
release as the stored-bundle provider ships, because it has no content to import that
the bundles do not already hold.

## Approved statements this change relaxes

| Statement | Where | Effect of this change |
| --- | --- | --- |
| The role must not manage local accounts. | `publish-ssh-ca-ansible-enrollment` design and `ansible-remote-access-enrollment` delta | Relaxed for accounts in mode `managed` only: create with a locked password and no groups. Still no sudo, PAM or directory changes, and no change to an account the role did not create. |
| Hypervisors and higher-risk targets fail closed without a separate policy. | same change, non-goals and delta | This change is that policy for hypervisors: class `elevated`, rule opt-in, one host at a time. Other higher-risk targets stay excluded. |
| A host with unmanaged `TrustedUserCAKeys` or `AuthorizedPrincipalsFile` is refused; existing trust is never adopted implicitly. | same change, delta and role preflight | Relaxed for two recognized layouts whose CA is in the bundle. Any other unmanaged source is still refused. |

Not relaxed: targeting by membership tuple; the per-child target limit; target holds
and their clearing permission; no AWX host or host-variable writes; one read-only
callback action; `devices.remote_access.ssh.ca_bundle.read` being separate from launch
permission; the role not creating, replacing or removing host keys (it reads public
keys); console credential custody, `devices.console.credentials.use` and exact owner
routing; per-action re-authorization and frame authentication for sessions.

## Risks / Trade-offs

- A certificate rule with no stored secret of its own is a new use of the rule model.
  Mitigation: the CA record is a real referent with its own lifecycle.
- A broad target query creates many device accounts. Mitigation: nothing is enrolled
  until launched; the fleet view shows counts before launch; reconciliation is paged.
- Probes add SSH connections. Mitigation: per-agent rate limit, jitter, 24-hour
  default, can be disabled.
- Enrollment-reported host keys are trusted without review. Mitigation: only for a
  device with no trusted key; a change always needs authorization; evidence is kept.
- Legacy principals are shared between hosts until re-enrollment. Mitigation: they are
  flagged on the device account and in the fleet view, and one enrollment replaces them.
- The work spans core, web-ng, the agent, the chart and a second repository.
  Mitigation: phases in `tasks.md`; each phase is useful alone.

## Migration Plan

1. Fix `defects.md` items independently.
2. Ship rules, CA records, principals, the exact membership test and the import
   (Decision 11). Certificate decisions switch to rules in the same release; the legacy
   policy is read only by the import.
3. Ship readiness, the probe and central host-key delivery behind agent capability
   negotiation. Device accounts with legacy principals are probed once and become
   `verified` where hosts already work.
4. Release the public content with adoption, account modes, the elevated class,
   results and the inventory plugin. Enable the direct and manual channels.
5. Enable the integrated channel when the callback and targeting changes it depends on
   are approved for mutation.
6. Ship the console changes; they are independent of 2 to 5.
7. Remove the chart values (Decision 11).

Rollback: until step 7, the previous release can be restored; it reads the legacy
policy again. Rules and device accounts created meanwhile are left in place. Hosts
adopted into the single layout are not converted back; the single layout accepts the
same certificates.

## Open Decisions for the owner

1. **Grant storage.** (a) Credential rules with the CA as the referenced credential
   (recommended, Decision 1). (b) A dedicated table reusing only validation and policy
   modules.
2. **Principal granularity.** (a) Per device account (recommended, Decision 2).
   (b) Per rule or group, as today.
3. **Default CA custody.** (a) A CA created from Settings whose key is stored encrypted
   in the unified credential store, with the external command signer as the hardened
   option (recommended; without it enabling certificate access still needs a
   deployment change). (b) External signer only.
4. **Deployments without an identity provider.** (a) Opt-in runtime setting for local
   identity, off by default (recommended, Decision 9). (b) SSO only; such deployments
   keep user-present key mode.
5. **Account handling.** (a) Per-account mode `existing` or `managed`, no default name
   (recommended, Decision 5). (b) `existing` only, as the newer role does today.
6. **Hypervisors.** (a) Enrollable as class `elevated` under rule opt-in (recommended,
   Decision 6). (b) Remain excluded from automated enrollment.
7. **Control-plane nodes.** (a) Administrator exclusion now, automatic classification
   when an inventory signal exists (recommended). (b) Block general availability on an
   automatic signal.
8. **Channel order.** (a) Direct and manual first, integrated when its prerequisites
   allow mutation (recommended). (b) Integrated first.
9. **First host key.** (a) Trust the key an enrollment result reports for a device with
   no trusted key (recommended, Decision 8). (b) Record it as pending for review.
10. **Console rule target meaning.** (a) Requested device or its owning host
    (recommended, Decision 10). (b) Requested device only, with a migration of existing
    rules.
11. **Periodic probe.** (a) On by default every 24 hours (recommended). (b) Off by
    default.
12. **Chart value removal.** (a) Remove one release after the import ships and refuse
    to render while it is set (recommended, Decision 11). (b) Ignore it silently.
    (c) Keep it one more release.

The spec deltas are written to the recommended options. A different choice changes
the named requirement and its tasks.

## Not established from the code

- Whether a credential secret record can hold public material with an external signer
  reference and no payload, or whether kind `ssh_user_ca` needs a schema change
  (`C/network_credential_secret.ex:309-455` was read for attributes only).
- Whether the identities `unique_integration_id` and `unique_controller_id`
  (`C/network_credential_rule.ex:313-314`) limit a deployment to one rule per
  integration, which would prevent a console rule beside an inventory rule. Not traced.
- The SRQL expression that selects exactly one device UID, and the cost of the exact
  membership test on a large inventory. Not measured.
- Whether stock Ubuntu 24.04 fails the current role preflight because of
  socket-activated sshd. Inferred from the preflight condition; not run.
- Whether sshd distinguishes an untrusted CA from a missing principal to the client.
  Assumed not.
- The exact Proxmox privilege names, the paths they must be granted on, and whether a
  node console can be opened with an API token. To be confirmed on a test cluster.
- How a Proxmox VE node's own SSH management interacts with a drop-in and an
  authorized-principals file. Assumed independent because root login and root keys are
  untouched; needs the elevated test.
- Whether locally authenticated ServiceRadar accounts have a second factor.
- Whether the session lifecycle defect in `defects.md` item 4 has other entry points
  than the one traced.
- Which existing reason codes the AWX target-readiness model will finally use; this
  change refers to them by capability, not by name.
- Statements about `R/` and about other OpenSpec changes come from surveys of those
  files; the role's task files were not re-read line by line for this proposal.
