# Change: Complete secure agent-routed access

## Why

ServiceRadar already contains most of an agent-routed SSH, Proxmox console, and desktop/RDP stack, but the deployed feature is not operationally complete. The live `demo` deployment enables only the RDP control-plane flag, leaves SSH and the SSH CA signer disabled, has no successful generic SSH session, has 24 Proxmox console sessions stuck in `requested`, points its only RDP target at a stale unlinked device identity, and advertises RDP from a helper whose live connector proof remains incomplete.

The partial paths also disagree about security and rendering. Proxmox guest sessions can be routed toward the guest instead of its parent PVE, QEMU RFB/VNC bytes are forwarded into an xterm terminal, inventory credentials can qualify as reusable console credentials, and the legacy Proxmox broker lacks the generic remote-access broker's atomic ticket, continuous authorization, and authenticated return-route controls.

## What Changes

- Add an authoritative readiness model for SSH, RDP, PVE/LXC terminal consoles, and QEMU graphical consoles. UI actions and advertised capabilities remain unavailable until deployment policy, device identity, target registration, route health, adapter/helper state, target trust, and credential mode are all ready.
- Package and configure the existing ServiceRadar SSH CA signer and certificate policy, generate memory-only per-session SSH keys on the selected edge agent after attach, and enroll Linux targets with the public CA plus target-specific principals through the existing Ansible workflow. No ServiceRadar PAM module or reusable bastion key is introduced.
- Publish reusable, idempotent Linux SSH-CA enrollment, verification, rotation, and rollback content from the public `serviceradar-ansible` repository. Register that repository in ServiceRadar/AWX and launch the playbooks through ServiceRadar rather than configuring the demo fleet by hand.
- Add reusable delegated automation callback grants for Ansible jobs that must call ServiceRadar APIs. Integrated launches require the logged-in user's profile to authorize both `ansible.runs.launch` and every declared callback action, then mint a short-lived, action/run/target/policy-bound bearer grant whose issuance-time authority is a permanent ceiling and whose current authorization is rechecked on use. The playbook fetches the public CA bundle without receiving the user's normal token or a general ServiceRadar API key.
- Make Ansible fleet targeting collision-safe across the `farm01` and `tonka01` Proxmox inventories. Launch identity is bound to controller ID, inventory ID, AWX host ID, canonical device UID, and current `ansible_host`; duplicate display hostnames never form an unqualified global limit.
- Fix AWX identity, launch, result, and audit fail-open gaps before fleet use: inventory ID is preserved end to end, empty limits are rejected, template/inventory compatibility is enforced, run targets/events are host-ID aware, and the human actor plus exact target/limit snapshot is immutable.
- Converge Proxmox consoles on the hardened generic remote-access session and broker path, including atomic single-use attach, continuous authorization, authenticated agent/gateway binding, audit, recording policy, timeout, revocation, and cleanup.
- Resolve a Proxmox guest's parent PVE and edge route from trusted virtualization relationships. Fail closed when canonical identity maps to multiple active provider references, nodes, or VMIDs.
- Make normalized Proxmox host/guest provider references cluster/provider-instance scoped so same-named Farm and Tonka nodes and overlapping VMIDs cannot overwrite each other; migrate or quarantine legacy unscoped relationships before enabling consoles.
- Deliver PVE host and LXC `termproxy` sessions with xterm through the terminal-console child. Define a separately approved QEMU graphical-console child whose protocol-aware RFB adapter emits the existing desktop-media framebuffer contract; raw VNC bytes remain unavailable and MUST NOT be rendered as terminal text meanwhile.
- Replace the Proxmox inventory-credential fallback with explicit, least-privilege `console_access` rules. PVE API tokens, console tickets, cookies, CSRF values, VNC passwords, and SSH keys remain session-scoped and out of browser-visible or durable assignment state.
- Gate RDP readiness on completion of the existing `add-remote-access-desktop-rdp` owner, including launch workflow, agent-side configuration delivery, evidence-based helper readiness, NLA, and verified TLS/server identity against the controlled Windows target reachable from `agent-sr-test-pve04`.
- Surface SSH, RDP, and provider-console actions on device details from server-derived readiness. Windows devices with a ready RDP target show **Connect**, and Proxmox guest actions use guest-to-parent relationships even when the guest has no discovered IP.
- Add deployed browser-to-agent-to-target tests for `192.168.2.22`, `192.168.1.62`, the controlled Windows RDP target, PVE host/LXC terminal consoles, and QEMU graphical consoles, including denial, route-loss, timeout, and secret-redaction cases.
- Use ServiceRadar's Ansible run hierarchy to preflight, canary, roll out, and verify public-CA enrollment across eligible Linux guests in both Proxmox clusters, with per-host outcomes feeding remote-access readiness.
- Reconcile completed remote-access OpenSpec changes into canonical specs and update the Teleport-parity matrix so the specifications, docs, code, and deployed readiness state agree.

This document is the program-level architecture and sequencing proposal. It does not authorize conflicting implementation against the current active specs. Delivery is split into prerequisite/child changes: canonical-spec reconciliation; AWX identity/launch safety plus callback grants; the public Ansible role; agent-routed SSH enablement; Proxmox provider identity plus PVE/LXC terminal console; and a separately reviewed QEMU graphical-console change. The existing `add-remote-access-desktop-rdp` and `expand-remote-access-teleport-parity` changes retain ownership of RDP completion and the parity matrix. Each implementation change requires its own exact deltas and approval after its prerequisites are reconciled.

**BREAKING**: A read-only Proxmox inventory credential rule no longer implicitly authorizes console access. Existing console actions or capability advertisements that cannot prove end-to-end readiness will be hidden or reported unavailable until an explicit console rule and protocol proof exist. Ansible launches that lack an unambiguous controller/inventory/host-ID mapping, a non-empty exact limit, or a compatible prompted/fixed inventory will be rejected instead of falling back to a template-wide run.

## Impact

- Affected specs: `remote-access-readiness` (new), `ssh-access-enrollment` (new), `proxmox-guest-console` (new), `edge-architecture`, `agent-connectivity`, `device-inventory`; bounded child changes solely own the callback and public Ansible enrollment capability deltas
- Related active changes: `add-secure-agent-routed-remote-access`, `add-proxmox-plugin-credential-rules`, `add-remote-access-desktop-rdp`, `expand-remote-access-teleport-parity`, `add-proxmox-guest-network-identity`, `fix-proxmox-inventory-plugin-reliability`, `harden-remote-access-security`
- Affected code: `elixir/serviceradar_core`, `elixir/web-ng`, `elixir/serviceradar_agent_gateway`, `go/pkg/agent`, `go/cmd/wasm-plugins/proxmox`, `rust/rdp-adapter`, native add-on packaging, Helm/demo values, ServiceRadar Ansible catalog/launch targeting, the public `/Users/mfreeman/src/serviceradar-ansible` repository, remote-access documentation, and deployed E2E tests
- Operational impact: new SSH user-CA secret/public-key lifecycle, public AWX-importable enrollment playbooks, collision-safe multi-inventory rollout, explicit Proxmox console credentials with `VM.Console`/`Sys.Console`, corrected demo target/route records, and opt-in protocol rollout gates

## Delivery boundaries

- `reconcile-remote-access-specs` is a separate prerequisite/archive PR. It reconciles completed foundations into canonical specs and resolves contradictions among the still-active Ansible, Proxmox credential, hypervisor enrichment, hardening, RDP, and parity changes.
- `secure-awx-callbacks-and-targeting` owns collision-safe AWX identity/launch semantics, user-profile permission checks, attenuated callback grants, custom credential injection, and the demo AWX farm/Tonka inventory configuration.
- `publish-ssh-ca-ansible-enrollment` owns the reusable public Ansible collection/role, tests, documentation, and public-repository pull request.
- `enable-agent-routed-ssh` owns signer packaging, selected-agent key generation, target-specific certificate principals, host-key trust, readiness evidence, device UI, and deployed SSH proofs.
- `fix-proxmox-identity-and-terminal-console` owns provider-instance identity migration, explicit console credentials, parent-PVE routing, and PVE/LXC terminal consoles on the generic broker.
- `add-proxmox-qemu-graphical-console` is a separately approved child for dependency/license/SBOM review, RFB parsing and fuzzing, desktop-media translation, resource bounds, and live QEMU proof.
- `add-remote-access-desktop-rdp` remains the sole owner of the RDP adapter, helper, launch UI, trusted Windows target, and live proof; this program only gates readiness on its completion.
- `expand-remote-access-teleport-parity` remains the owner of parity status updates after each child lands.
