# Change: Fix Proxmox identity and terminal console delivery

## Why

ServiceRadar currently persists Proxmox virtualization references without a
stable provider-instance namespace. Two independent PVE estates can therefore
emit the same cluster display name, node name, guest type, or VMID and collide
in inventory. Farm and Tonka already demonstrate the important failure shape:
the same PVE node name must never allow one provider instance to overwrite or
route a console through the other.

The existing Proxmox console path also has a split security model. It can select
provider-specific sessions and brokers, derive targets heuristically, use the
guest's route instead of its parent PVE route, and let an inventory-enrichment
credential qualify for interactive access. QEMU graphical RFB/VNC is presented
alongside PTY terminal modes even though it requires a different transport and
renderer.

This child change delivers the bounded terminal-console portion of the approved
secure remote-access program: migrate or quarantine Proxmox identity by stable
provider instance, route PVE/LXC/explicit QEMU serial terminals through the
authoritative parent PVE, require an explicit `console_access` credential, and
use the hardened generic remote-access session and broker lifecycle.

## What Changes

- Introduce an immutable `provider_instance_ref` for each registered Proxmox
  integration endpoint. It remains stable across cluster display-name changes
  and credential rotation and namespaces all Proxmox provider references,
  relationships, targets, and console policy.
- Replace unscoped Proxmox references with instance-scoped references such as
  `proxmox:<provider-instance>:node:<node>` and
  `proxmox:<provider-instance>:guest:<node>:<qemu|lxc>:<vmid>`.
- Classify legacy rows before enabling the new uniqueness contract. Rows that
  map provably to one provider instance are migrated transactionally; ambiguous
  or conflicting rows are quarantined and re-ingested rather than guessed.
- Preserve same-name Farm/Tonka resources independently, including nodes,
  guests, overlapping VMIDs, parent relationships, NIC/disk/datastore
  relationships, and console targets.
- Resolve a guest terminal through exactly one active provider instance,
  virtualization guest, guest type/VMID, authoritative parent PVE host,
  registered PVE endpoint and TLS policy, and eligible parent-selected edge
  route. The guest remains the audited/display target.
- Support only PTY terminal transports in this child: PVE node `termproxy`, LXC
  `termproxy`, and QEMU `termproxy` when an authoritative configuration proves
  that an explicit serial console is registered and available.
- Require exactly one enabled, policy-selected credential rule whose purpose is
  `console_access` and whose provider instance, resource, endpoint, route, API
  path/method, privilege, and TTL scope covers the terminal session.
- Remove inventory and generic credential fallback for Proxmox terminals.
  Browser requests cannot select a credential rule, endpoint, provider
  reference, node, VMID, route, trust mode, or terminal mode.
- Translate new Proxmox terminal opens into the hardened generic remote-access
  session/broker lifecycle, including atomic one-use attach, create/attach and
  periodic authorization, authenticated and integrity-protected route frames,
  bounded timeouts, recording policy, audit, revocation, route-loss closure,
  and orphan cleanup.
- Add a provider-terminal runtime capability and server-derived device action
  readiness. Re-evaluate all identity, parent, route, capability, TLS,
  credential, permission, approval, and hold inputs at create and attach.
- Resolve the short-lived provider grant only after atomic browser attach.
  Proxmox tokens, tickets, cookies, CSRF values, and terminal proxy credentials
  stay out of browser state, URLs, durable assignments, logs, audit, recordings,
  and reusable agent configuration and are discarded on every terminal path.
- Add migration, ambiguity, wrong-parent, wrong-route, credential-isolation,
  replay, authorization, timeout, cleanup, UI-readiness, and live provider proof
  gates before the secure-off terminal capability can be enabled.
- **BREAKING**: ambiguous or unscoped legacy Proxmox rows cannot authorize or
  route a console until migrated or re-ingested; an inventory-enrichment or
  generic credential no longer qualifies for interactive console access; and a
  QEMU guest without an explicitly registered serial console is unavailable in
  this terminal child.

## Impact

- Affected specs: `device-inventory`, `network-credential-rules`,
  `proxmox-console-access`
- Affected code: Proxmox discovery/enrichment and virtualization identity,
  credential rule resolution and grants, generic remote-access session/broker,
  edge agent Proxmox terminal adapter, gateway routing, device-detail readiness,
  terminal UI, migrations, cleanup workers, audit/recording, and deployment
  configuration
- Operational impact: provider instances must be registered with stable IDs;
  legacy identity requires a dry-run classification and bounded re-ingestion;
  interactive terminals require separate least-privilege credentials and remain
  secure-off until migration and live proof gates pass

## Dependencies

- The generic remote-access session/broker and its hardening contracts from
  `add-secure-agent-routed-remote-access` and
  `harden-remote-access-security` must be available before terminal enablement.
- The provider-neutral virtualization and guest network identity foundations
  from `refactor-provider-neutral-hypervisor-enrichment` and
  `add-proxmox-guest-network-identity` must be reconciled before the scoped
  identity migration is enforced.
- The credential rule foundation from
  `add-proxmox-plugin-credential-rules` must be available. This change narrows
  its interactive-console behavior and replaces the original provider-specific
  session path for new terminal sessions.
- Identity migration and parent-PVE relationship validation must complete
  before terminal readiness or actions can be enabled.

## Goals / Non-Goals

### Goals

- Make Proxmox host and guest identity collision-safe across provider instances.
- Fail closed rather than guess when legacy identity, parent PVE, endpoint,
  route, terminal mode, or console credential is ambiguous.
- Deliver PVE, LXC, and explicitly configured QEMU serial terminals on the
  generic hardened remote-access path.
- Keep interactive provider credentials purpose-isolated, session-scoped,
  least-privilege, and absent from durable and browser-visible surfaces.
- Expose device actions only from current authoritative readiness and prove
  lifecycle cleanup and cross-instance isolation before rollout.

### Non-Goals

- Do not implement QEMU graphical RFB/VNC transport, framebuffer rendering, or
  `vncproxy`/`vncwebsocket`. That is owned by the separate
  `add-proxmox-qemu-graphical-console` child.
- Do not implement RDP or change its readiness, credential, transport, or UI
  contracts. RDP remains owned by `add-remote-access-desktop-rdp`.
- Do not broaden global SSH enablement, SSH certificate custody, file transfer,
  or generic cross-protocol readiness.
- Do not make cluster display names, node names, VMIDs, guest hostnames,
  discovered IPs, or browser fields authoritative provider-instance identity.
- Do not preserve the legacy provider-specific broker as a second path for new
  sessions or re-enable inventory credential fallback during rollback.
