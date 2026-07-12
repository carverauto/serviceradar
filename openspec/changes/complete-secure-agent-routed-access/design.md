## Context

The existing remote-access foundation is reusable: browser sessions already flow through web-ng, the core broker, the authenticated gateway control stream, and the selected Go agent; the agent has a real SSH PTY adapter with host-key verification; and remote-access resources already model RBAC, approval, tickets, audit, recording, and route binding.

The missing work is integration, truthful readiness, and protocol-specific completion. Live `demo` inspection on 2026-07-12 found:

- `agent-dusk01` (`192.168.2.22`) and `agent-sr-test-pve04` (`192.168.1.62`) connected and advertising generic remote-access capabilities.
- SSH, the SSH CA signer, application access, and TCP access disabled in the control plane; only the RDP flag was enabled.
- Neither Linux test host configured with `TrustedUserCAKeys`; both accept `mfreeman` and passwordless sudo.
- AWX/ServiceRadar inventory is fed by two Proxmox clusters, `farm01` and `tonka01`, whose guests may share display hostnames while using different IP addresses. A global hostname-only AWX `limit` is therefore unsafe.
- Live AWX currently has one Proxmox inventory/source representing the farm-side hosts; no distinct `tonka01` AWX inventory/source is configured. Most AWX and Proxmox twins remain separate canonical rows.
- One stale RDP target at `192.168.2.126:3389`; the reachable controlled Windows RDP service is `192.168.1.45:3389` from `agent-sr-test-pve04` and corresponds to Proxmox guest `pve01/qemu/155` (`sr-win-test01`).
- One assigned RDP helper with no add-on runtime status, while the agent advertises RDP and the packaged experimental helper reports connector readiness from a compile-time flag.
- 24 Proxmox console sessions, all permanently `requested`; no generic SSH sessions, host keys, or recordings.
- Proxmox guest and network sightings that are not always reconciled to one canonical device, plus active provider-reference collisions that are unsafe for console routing.
- The Proxmox integration already reaches both provider instances, but normalized host/guest refs such as `proxmox:node:pve02` and `proxmox:guest:pve02:qemu:<vmid>` omit the cluster. Same-named Farm/Tonka nodes therefore collide in virtualization tables.

Read-only root SSH validation confirmed the live PVE topology:

- `farm01`: `pve01` through `pve04`, currently online at `192.168.2.10` through `192.168.2.13`.
- provider/site `tonka01`, PVE cluster name `tonka`: `pve02` at `192.168.10.136` and `pve03` at `192.168.10.235` online; `pve01` is present but offline.

The existing Tonka Proxmox rule/assignment is producing cluster and guest data. The missing normalized Tonka hosts are an identity/persistence collision, while the missing Tonka AWX hosts are a separate inventory-source configuration gap.

Official PVE API contracts provide `termproxy` for node, QEMU serial, and LXC terminal sessions and `vncproxy` plus `vncwebsocket` for graphical QEMU sessions. Guest calls require `VM.Console`; node shell calls require `Sys.Console`. These provider credentials and returned tickets are privileged interactive-access material and cannot reuse the read-only inventory trust boundary implicitly.

## Goals / Non-Goals

### Goals

- Make generic Linux SSH work from device details through the selected edge agent using short-lived ServiceRadar SSH certificates and existing target accounts.
- Make PVE host, LXC, and QEMU console actions originate from the discovered Proxmox device/guest and route through the parent PVE without direct browser reachability to PVE.
- Make the controlled Windows RDP target work through the selected edge agent with NLA, verified target identity, a graphical renderer, disabled redirection, and clean teardown.
- Expose precise, sanitized readiness and failure reasons without leaking target or credential details.
- Reuse the generic remote-access broker, control stream, recording, RBAC, and audit paths rather than extending the weaker legacy Proxmox session path.

### Non-Goals

- Do not add a ServiceRadar PAM authentication module. OpenSSH CA trust authenticates the certificate; the target's existing local/PAM/LDAP account and session rules remain authoritative.
- Do not create an arbitrary browser-controlled TCP proxy, browser-selected agent route, or browser-selected upstream host/port.
- Do not enable clipboard, drive, printer, audio, smart-card, or file redirection for RDP.
- Do not add SPICE, vSphere, database, or Kubernetes access in this change.
- Do not expose PVE API tokens, tickets, cookies, CSRF values, or reusable target credentials to browser code.
- Do not declare RDP or QEMU graphical console production-ready based only on compilation, mocked tests, or local helper presence.

## Architecture

All interactive access uses one control-plane trust path:

```text
browser
  -> authenticated web-ng API / browser stream
  -> generic core remote-access session and broker
  -> authenticated gateway control stream
  -> selected, connected edge agent
  -> registered SSH/RDP target or parent PVE endpoint
```

For a Proxmox guest, the audited display target and network upstream are distinct:

```text
guest canonical device UID
  -> virtualization guest (provider ref, guest type, VMID)
  -> virtualization host (PVE node and canonical host UID)
  -> registered PVE endpoint and TLS identity
  -> eligible edge agent and explicit console credential rule
```

Browser parameters can select only an authorized action or registered target ID. They cannot override the resolved provider reference, PVE node, VMID, endpoint, TLS policy, credential rule, agent, gateway, or recording policy.

## Decisions

### Decision: Compute readiness from authoritative dependencies

Each access mode exposes a server-derived readiness result:

- deployment feature policy enabled;
- canonical device identity is active and unambiguous;
- a registered target or provider console target exists;
- an eligible agent/gateway route is connected;
- the agent reports the effective protocol capability from applied config and a ready adapter/helper;
- host key, TLS CA/server identity, or provider endpoint trust is configured;
- an allowed credential custody mode or explicit console rule is available;
- the actor has RBAC and any required approval.

The UI shows **Connect** only when these dependencies are ready. Authorized operators can see stable reason codes such as `feature_disabled`, `identity_ambiguous`, `target_missing`, `route_offline`, `adapter_unready`, `trust_unconfigured`, `credential_unavailable`, or `approval_required`. Public errors never include raw dial, authentication, host-key, TLS, PVE, or helper error strings.

Compile-time linking is not an RDP readiness proof. The RDP helper must report a locally verifiable completed connector implementation, and a deployment remains unready until a registered target passes the controlled end-to-end proof.

Readiness is a live evaluation over versioned evidence, not a retained success Boolean. Reusable operational evidence is intersected with the current actor's RBAC and approval at action display, create, attach, and periodic authorization. Each evidence record includes schema/deployment/protocol/action; canonical target and identity revision; endpoint/trust digest; provider instance/node/type/VMID where applicable; selected agent/gateway/route class and affinity revisions; agent build/applied config; adapter/helper/add-on identity/version/digest/health; graphical renderer/media-contract build; host-key/TLS/provider trust revision; credential-custody and recording-policy revisions without secrets; SSH signer policy and active CA key IDs; tested capabilities; result/reason; observation/freshness times; evidence digest; and audit reference.

Evidence has two levels: deployment/adapter proof for an exact build and route class, and target proof for the exact endpoint or provider resource, route, trust, and credential policy. It becomes stale on feature disablement, identity/endpoint/provider relationship change, host-key or TLS change, VM migration, route disconnect or affinity change, agent/gateway/config/adapter/helper/add-on/renderer change, credential/CA/recording/approval-policy change, a failed later probe, or freshness expiry. Route reconnection requires a new bounded target probe. Session creation atomically re-evaluates current dependencies and never trusts a previously rendered UI state.

### Decision: Use short-lived SSH certificates without a new PAM module

The control plane packages the existing `serviceradar-sshca-signer` behind the existing ServiceRadar signer interface. The CA private key is mounted only into that signing boundary. Targets receive only the public CA and atomic sshd configuration for `TrustedUserCAKeys` plus explicit principal mapping.

After authorization and atomic attach-ticket consumption, the selected agent generates a fresh Ed25519 keypair inside the per-session SSH runtime. It sends only the public key, session nonce, and authenticated session/target/route binding to the signer and receives the certificate only over that same selected route. The private key never enters the browser, web-ng, core, gateway, audit, recording, logs, traces, or durable agent state. A repeat request for the same session and public key is idempotent; a different public key for the session is rejected.

Each integrated target uses an opaque target-specific certificate principal installed for the approved local account through `AuthorizedPrincipalsFile`; a fleet-wide `mfreeman` principal accepted on every enrolled host is not sufficient. The certificate includes `source-address` when the selected route has a stable registered egress address, but target-specific principals remain mandatory. It permits PTY only and omits agent, port, X11, and user-rc forwarding. Certificate validity is bounded to the attach/open authentication window, with a two-minute policy maximum, while the independent session timeout controls the established connection. User-present keys remain a separate explicitly enabled custody mode and never become an automatic fallback.

The initial demo policy maps the authorized actor to a target-specific opaque principal authorized for the existing `mfreeman` target account. Enrollment preserves current PAM/account/session behavior, validates sshd syntax before reload, supports rollback, and verifies certificate login from the selected edge agent before marking the device ready.

### Decision: Publish enrollment as reusable Ansible content

The public `serviceradar-ansible` repository is the source of truth for Linux target enrollment. The feature branch adds root-level playbooks that AWX can discover plus a reusable role for:

- preflight and check-mode validation;
- installing one or more public SSH user CA keys for overlap rotation;
- managing an isolated sshd drop-in and explicit per-local-account principal files for target-bound integrated access;
- validating local accounts, CA key syntax, file ownership/mode, and `sshd -t` before reload;
- distribution-aware SSH service reload with block/rescue rollback;
- post-change effective-config verification and a non-destructive removal/rollback workflow.

The role never accepts or distributes the CA private key. It rejects private-key/certificate blobs, invalid CA fingerprints, unsafe account names, path traversal, newlines, control characters, and principal-option injection before any root-owned write. It supports multiple public user-CA keys for overlap rotation, detects `ssh` versus `sshd`, verifies the main configuration actually includes the drop-in directory, detects conflicting pre-existing `TrustedUserCAKeys`, and validates effective output with `sshd -T`. Its public variables are documented, typed/validated, idempotent, safe in check mode, and suitable for Debian/Ubuntu and RHEL/Rocky/Alma families.

The repository becomes collection-ready with Apache-2.0 `LICENSE`, `galaxy.yml`, runtime metadata, role documentation, and changelog while preserving root AWX-discoverable wrappers. Forgejo CI runs YAML/Ansible lint, root-playbook syntax checks, and Molecule coverage for idempotence, two-key rotation, absent/offboarding, invalid-input zero-change behavior, and byte-for-byte rollback after forced validation/reload failure. The feature branch is pushed explicitly and reviewed through a pull request; automation never pushes directly to the repository's shared `main` branch.

ServiceRadar registers the public repository as a catalog source, binds the enrollment playbooks to AWX job templates, and records the repository revision and playbook content hash in each run so an operator can prove what configured a host.

The public repository contains no deployment-specific CA. Integrated enrollment retrieves the bundle through the delegated automation callback contract described below. The logged-in user's ServiceRadar profile must grant both `ansible.runs.launch` and the permission mapped to `remote_access.ssh_ca.bundle.read`, plus target policy and any required approval. Neither permission implies the other. The control plane, not the playbook form, chooses the callback action, CA trust policy, and target-keyed principal mapping.

The public playbooks use Ansible built-ins such as `assert`, `copy`, `template`, `file`, `command`, `service`, and `uri`; they do not require `serviceradar-cli` on AWX or on managed hosts. The callback request executes once in the AWX execution environment with `delegate_to: localhost`, `run_once: true`, and `no_log: true`; only the returned public bundle is distributed to targets.

### Decision: Use delegated automation callback grants, not user tokens

This program introduces a generic callback contract for Ansible and future automation integrations, while the first child registers only the read-only public-CA action. ServiceRadar MUST NOT forward the initiating user's browser/API access token to AWX. Before dispatch it creates the local child execution, immutable launch snapshot, and a pending opaque automation grant with:

- initiating human/service actor and issuance-time permission, tenant, target-policy, and approval snapshot;
- deployment/tenant, controller, inventory, job template, parent run, child execution, immutable SCM revision/content hash, and source request binding;
- explicit callback action allowlist, initially `remote_access.ssh_ca.bundle.read`;
- mandatory exact canonical-device/AWX-host target-set hash, CA/principal response-policy snapshot, and per-target mapping;
- audience `serviceradar-automation-callback-v1`;
- short not-before/expiry, idempotency policy, request budget, nonce, pending/active state, revocation, and terminal-use state.

The grant is an attenuated user capability, not a platform/service credential. Its effective authority is the intersection of:

```text
issuance-time actor/service permissions, tenant, target, approval, action, and deployment ceiling
  INTERSECT current enabled actor/service membership and permissions
  INTERSECT current run, job, target, approval, and policy state
  INTERSECT reviewed playbook action/schema declarations and immutable revision
  INTERSECT current action-registry and deployment maximum
```

Grant creation runs through an authorized Ash action with the initiating user's real scope. It checks both the playbook-launch permission and every callback-action permission before creating or dispatching the run, and rechecks them before activation and callback use. It MUST NOT use `SystemActor`, `authorize?: false`, a platform admin token, the AWX controller credential, or any other confused-deputy path to add authority. Later RBAC expansion cannot enlarge the issuance snapshot. An internal worker may transport the already-authorized grant reference, but it cannot alter the actor, actions, targets, TTL, request budget, or policy snapshot.

Scheduled automation uses an explicit owned service principal with fixed non-wildcard tenant, actions, catalog/template/revision set, target ceiling, TTL/budget maximum, owner, expiry, rotation, and disable controls. Workload OIDC or mTLS is preferred to long-lived bootstrap credentials. A service principal never inherits a platform worker's authority or impersonates a human.

Only a random bearer value is given to the reviewed AWX credential boundary; ServiceRadar stores its hash plus audit/policy state. The bearer remains pending and unusable until AWX returns an unambiguous job whose controller, inventory, template, revision, and exact limit match the child snapshot. ServiceRadar then atomically binds the controller-local job ID and activates the grant. A racing callback receives a bounded retryable pending response; definitive or ambiguous dispatch failure, mismatch, cancellation, relaunch/copy, or terminal state revokes it.

The callback endpoint rechecks the issuance ceiling, current actor/service and both required profile permissions, run/execution/job binding, allowed action, exact target/policy snapshot, expiry, budget, and revocation on every call. The one-read action atomically consumes one logical use. A retry with the same idempotency key may receive the cached byte-identical response after reauthorization; concurrent or later different keys are denied. Authentication failures do not consume the success budget but are separately rate limited and audited.

The endpoint derives a target-keyed response from the immutable snapshot with public CA keys, key IDs/fingerprints, overlap/retirement state, policy version, and approved target-specific principal mappings. It cannot sign certificates, read private keys, mutate targets, or call unrelated APIs. A response digest is only an integrity/audit fingerprint unless a separately specified pinned verification key and signature scheme is present.

The launch contract standardizes:

- `SERVICERADAR_AUTOMATION_CALLBACK_URL`;
- `SERVICERADAR_AUTOMATION_CALLBACK_TOKEN`;
- `SERVICERADAR_AUTOMATION_RUN_ID`;
- declared callback actions and response schemas in catalog metadata;
- a small reusable `serviceradar_automation_callback` Ansible role/task helper that performs canonical HTTPS with CA/hostname verification, no redirect or credential forwarding, bounded time/size, bearer injection, response schema validation, redaction, idempotent retry, and sanitized errors.

The token-bearing launch input is a first-class secret. ServiceRadar stores only public variables plus secret references/digests in run/audit rows. The plaintext grant is held in a single-resolution encrypted launch envelope whose authenticated data binds tenant, command, child execution, controller, inventory, template, dispatch agent, and expiry. Integrated jobs use a reviewed ephemeral AWX custom credential with an environment/header injector; survey fields, ordinary `extra_vars`, inventory variables, facts, artifacts, files, and managed-host variables are forbidden.

The authorized ServiceRadar dispatcher, AWX controller credential-decryption path, and selected execution-environment process are explicit trusted transient bearer-handling boundaries for this read-only action. The credential is detached/deleted and the grant revoked after terminal or ambiguous dispatch. Tests cover AWX job details/API, stdout/events, relaunch/copy, fact cache, artifacts, support bundles, analytics, failure logs, backups, and managed-host state. Agent commands, PaperTrail, OCSF events, logs, traces, and UI never contain the plaintext token.

No operator-created API key is required for integrated launches. ServiceRadar already authenticates the actor and uses its brokered AWX controller credential to launch the job; AWX already uses its machine credential to connect and become on targets. The CA private key never leaves the signer, and the callback token never reaches a managed target.

For external/manual workflows, `serviceradar-cli automation grants create` can mint a similarly scoped callback grant using the operator's normal interactive authentication, and `serviceradar-cli remote-access ssh-ca export` can retrieve an Ansible-compatible bundle. Unattended external automation uses only the explicit fixed-ceiling service-principal contract above; a general platform API key is neither required nor recommended.

The catalog UX shows the logged-in profile's required launch permission, each named callback action and mapped permission, why it is needed, response sensitivity, target scope, policy/approval requirements, TTL, and budget before confirmation. Each action registry entry declares security tier, effect, sensitivity, target binding, bearer/PoP rule, principal types, approval, limits, schema, retry, and audit. This program permits only `remote_access.ssh_ca.bundle.read`; secret-returning, mutating, signing, credential-minting, or reusable actions require a separate OpenSpec security review and stronger proof-of-possession where appropriate.

### Decision: Partition Ansible launches by authoritative inventory identity

The selected unit is a canonical ServiceRadar device linked to an AWX host snapshot:

```text
device UID
  -> controller ID
  -> inventory ID
  -> AWX host ID
  -> inventory_hostname / host name
  -> current ansible_host address
  -> Proxmox provider instance / cluster context
```

Before launch, ServiceRadar re-fetches each AWX host by ID and verifies that controller, inventory, host name, and `ansible_host` still match the stored device link. It also confirms that the bound job template uses the expected inventory. The AWX `limit` contains exact inventory host names only within that one inventory; it is never built from display hostname alone across inventories.

A fleet request spanning `farm01` and `tonka01` is partitioned into child jobs by `(controller_id, inventory_id, job_template_id)` under one parent ServiceRadar operation. Duplicate display names remain separate because every result is correlated through the child job and its snapshotted AWX host ID/device UID. The confirmation UI shows cluster/provider instance, inventory, host ID/name, `ansible_host`, and canonical device for every target.

The current ingestion and launch model must be corrected before this rollout:

- AWX integration identity is `(controller_id, inventory_id, host_id)`, not `awx:host:<hostname>`.
- A device can retain multiple AWX membership records; last-writer-wins `metadata.awx` is not the execution source of truth.
- A job launch rejects an empty target set, missing host name/address, incompatible fixed inventory, unsupported inventory prompt, or empty limit. It never omits `limit` and broadens to the whole template inventory.
- Run-target uniqueness and event correlation include controller/inventory/host ID, with the runner hostname treated as verified display/correlation data inside one child job.
- Create-target errors fail the parent launch rather than silently dropping a duplicate.
- The immutable audit includes the human actor, source surface/request ID, device/controller/inventory/host ID/name/address snapshot, actual escaped limit, selected inventory, check mode, playbook revision/hash, AWX job IDs, and per-host outcomes. A system actor may execute internal Ash operations but cannot replace the human requester in audit.

AWX host names must be unique within one inventory. Demo therefore creates separate `farm01` and `tonka01` inventories/sources, or uses deterministic cluster-qualified aliases such as `farm01__pve01` and `tonka01__pve01` with distinct `ansible_host` values. Separate inventories are preferred because they preserve source boundaries and make child-job partitioning explicit.

Rollout uses four gates: read-only preflight, native AWX check mode or a dedicated check job template, one canary per cluster/inventory, then bounded waves. Check mode is an explicit launch property; it is not emulated by an arbitrary extra variable. A host becomes SSH-ready only after the Ansible result verifies effective sshd CA/principal configuration and the selected ServiceRadar edge agent completes an actual certificate-authenticated SSH probe. A successful AWX task alone is not sufficient.

Discovery or a Linux label alone never authorizes enrollment. An eligible default-risk target must have one unambiguous canonical device; one selected controller/inventory/AWX-host membership and exact current `ansible_host`; supported OS and sshd layout; a validated non-root account; an authorized AWX machine/become credential; a reachable selected edge route; no unmanaged CA conflict, exclusion, or maintenance hold; and successful read-only preflight. PVE/hypervisor nodes, Kubernetes control planes, AWX, ServiceRadar, CNPG, identity/storage/control-plane systems, network/security appliances, and root target accounts are excluded by default. They require a separate higher-risk policy, explicit approval/snapshot, and canary. Waves partition by inventory/cluster, OS family, SSH layout, and risk class.

### Decision: Converge Proxmox on the generic broker

The Proxmox-specific session table and stream may remain as a compatibility facade during migration, but new sessions use the generic remote-access session state machine and broker guarantees:

- transactional single-use attach tickets;
- create and attach authorization plus periodic reauthorization;
- selected agent and gateway binding on both outbound and inbound frames;
- frame authentication/integrity where the generic route requires it;
- bounded idle and absolute timeouts, revocation, route-loss termination, and orphan cleanup;
- uniform audit, recording policy, terminal outcomes, and sanitized errors.

The agent consumes `ready` and activity signals so sessions progress through `requested -> attached -> opening -> active -> closing -> closed`. A reaper closes requested/attached sessions that expire without opening.

### Decision: Separate terminal and graphical Proxmox transports

- PVE node and LXC `termproxy` sessions emit typed PTY data/resize/control frames and render with xterm.
- QEMU uses `termproxy` only when a registered serial console is explicitly selected and available.
- Graphical QEMU sessions use `vncproxy`/`vncwebsocket` on the selected agent. A protocol-aware RFB adapter consumes provider authentication and emits the existing desktop-media framebuffer/control contract. Raw RFB bytes never enter the terminal frame type or xterm renderer.
- SPICE is out of scope.

This keeps provider tickets and VNC authentication material on the edge agent while reusing the RDP desktop-media path for graphical rendering, backpressure, frame quotas, input policy, watermark/consent, and cleanup.

### Decision: Use explicit session-scoped console credentials

Read-only Proxmox inventory tokens no longer qualify automatically for console access. An operator creates a separate `console_access` rule scoped to a provider instance/site, explicit PVE endpoints, allowed guest/node resources, selected agents, and the minimum PVE privileges (`VM.Console` and optionally `Sys.Console`).

Core resolves the encrypted secret only after session authorization and returns a bounded one-session grant for the selected target, provider instance, agent, gateway, protocol, and TTL. Plaintext is not placed in durable add-on assignment params, session metadata, URLs, logs, traces, recordings, or browser messages. The agent host enforces the resolved endpoint and WebSocket/HTTP path allowlist even when provider-specific endpoint construction remains in the Proxmox adapter.

### Decision: Fail closed on hypervisor identity ambiguity

Remote console readiness requires exactly one active provider instance, guest provider reference, parent host, guest type, and VMID for the canonical device. Cross-host or same-host collisions do not pick a winner. The device remains observable, but console actions report `identity_ambiguous` until reconciliation or operator correction resolves the conflict.

Normalized provider references are cluster/provider-instance scoped, for example:

```text
proxmox:<provider-instance>:node:<node>
proxmox:<provider-instance>:guest:<node>:<qemu|lxc>:<vmid>
```

The immutable provider-instance identifier is not derived only from a display cluster name that an operator may rename. Existing cluster-scoped integration IDs can seed migration, while legacy unscoped refs remain aliases only after they resolve uniquely. Host, guest, datastore, network, console-target, and relationship uniqueness all include provider instance. Ambiguous legacy rows are quarantined for console use rather than overwritten.

An IP is not required for a native PVE console because transport targets the parent PVE. Ordinary guest SSH/RDP still requires a registered network target or a trusted canonical IP association.

### Decision: Complete RDP before enabling it

The existing `add-remote-access-desktop-rdp` change remains the sole implementation owner. This program contributes only the cross-protocol readiness gate. RDP remains opt-in and unavailable until that change proves all of the following:

- the feature-set assignment actually updates agent config;
- the signed `rdp` add-on is approved, installed, executable, and reports runtime status;
- helper readiness reflects a completed connector, not a compile-time cfg;
- the browser has a launch workflow that creates, attaches, supplies an allowed credential, waits for activation, and then opens WebRTC;
- the registered Windows target uses the reachable address, verified TLS CA/server identity, NLA-required policy, selected agent, disabled redirection, and metadata-only recording;
- live screen, keyboard/pointer input, backpressure, timeout, route loss, credential clearing, audit, and cleanup pass.

Demo's current RDP UI flag does not override these readiness checks.

### Decision: Isolate QEMU graphical console in a protocol child

The PVE/LXC terminal child does not implement or enable QEMU graphical access. A separate `add-proxmox-qemu-graphical-console` proposal must select and review the RFB dependency boundary; close license and SBOM requirements; threat-model PVE WebSocket authentication, parser input, media/input translation, and resource exhaustion; define fuzzing and protocol quotas; and pass an exact provider-instance/node/VMID live proof. Until that child is approved and complete, QEMU graphical readiness is false and raw RFB bytes are rejected from terminal, core, browser, and xterm paths.

## Security and Failure Handling

- Access decisions bind actor, device/target, protocol, agent, gateway, credential rule/grant, trust policy, approval, and recording policy to one session.
- Session grants, provider tickets, passwords, private keys, cookies, and CSRF values are memory-only and zeroized or discarded on close/failure where supported.
- The SSH user CA public bundle may be present in an audited AWX job result. Callback grants are transiently available only inside the named dispatcher/AWX/EE bearer boundary and MUST NOT appear in ordinary playbook variables, run records, events, facts, artifacts, or target files; the CA private key and ServiceRadar/AWX/machine credentials never enter the playbook data path.
- Browser and agent errors use typed public codes; detailed causes remain in access-controlled structured logs with secret redaction.
- Target reachability probes are bounded and may test only registered endpoints from their selected agent.
- QEMU framebuffer and RDP media enforce resolution, frame-rate, bitrate, byte-credit, queue, and input-token bounds.
- Console and RDP launch are denied when the required target CA/server name or PVE TLS policy is absent.

## Migration and Rollout

1. Land a separate archival-only prerequisite PR that reconciles the already-deployed remote-access foundations into canonical specs. Do not combine archive operations with feature implementation.
2. Repair the still-active Ansible, Proxmox identity/guest, RDP, and parity proposals with exact `MODIFIED` requirements where this discovery found contradictions.
3. Approve and land `add-authoritative-remote-access-readiness` with versioned evidence, reason codes, sanitized errors, and false-capability withdrawal while every incomplete protocol remains unavailable.
4. Approve and land `harden-ansible-awx-targeting`, then `add-automation-callback-grants`. Only after those land may the authorized demo AWX configuration be changed to create distinct Farm/Tonka inventories, the reviewed project/templates, and the ServiceRadar callback custom credential type.
5. Approve and land `publish-ssh-ca-ansible-enrollment`, including its public-repository pull request and stable reviewed revision.
6. Approve and land `complete-ssh-certificate-access`; enroll `192.168.2.22` and `192.168.1.62` as canaries, then eligible fleet partitions, and pass browser-to-agent-to-host SSH proofs.
7. Approve and land `scope-proxmox-provider-identities`, migrate/quarantine legacy collisions, then approve `add-proxmox-terminal-console` and pass PVE/LXC proofs using explicit console credentials.
8. Separately approve and land `add-proxmox-qemu-graphical-console` before any QEMU graphical enablement.
9. Complete the existing `add-remote-access-desktop-rdp` against the controlled Windows target; do not duplicate its implementation in another change.
10. Update the existing Teleport-parity change after each deployed proof. Enable only modes with current evidence and retain secure-off defaults elsewhere.

Rollback disables the affected mode in deployment policy, revokes outstanding sessions/grants, and leaves inventory/monitoring unaffected. Target SSH CA enrollment can be rolled back with the Ansible role while preserving the pre-change sshd configuration.

## Risks / Trade-offs

- The QEMU RFB adapter is materially larger than terminal proxying. Reusing the desktop-media contract avoids a second browser security model but requires protocol-aware edge work and real PVE tests.
- Canonical-device collisions can temporarily hide console actions. This is safer than routing an operator to the wrong VM.
- Separate console credentials add operator setup. They prevent a read-only inventory token from silently becoming an interactive shell credential.
- Agent-generated ephemeral keys enlarge the selected agent's trusted runtime boundary, but keep private material out of browser and control-plane surfaces. Target-specific principals prevent a session certificate from authenticating to another enrolled host.
- AWX launches ultimately use inventory host-name limits. Re-fetching by host ID, verifying `ansible_host`, partitioning by inventory, and showing cluster context prevent duplicate display names from becoming ambiguous targets.
- Reconciling old active OpenSpec changes requires a separate archive PR before any child can safely modify their canonical requirements.

## Open Questions

- Confirm the exact PVE node/LXC/QEMU fixtures used for live terminal and graphical proof after ambiguous provider references are remediated.
- Confirm the Windows RDP certificate's expected DNS server identity and CA bundle identifier before replacing the stale demo target.
- Record the exact distinct `farm01` and `tonka01` AWX inventory/source definitions, instance-group reachability, machine/become credential bindings, and deterministic inventory host names during the AWX-targeting child. The operator has authorized full in-cluster AWX administration after that child is approved.
