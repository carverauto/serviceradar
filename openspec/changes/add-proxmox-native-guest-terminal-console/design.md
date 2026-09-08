## Context

The existing Proxmox console implementation deliberately supports SSH-backed
PVE host shells only. It models QEMU and LXC console requests but rejects them
until a native provider connector exists. The demo also currently contains
legacy hypervisor identity rows, duplicate guest names/VMIDs, unresolved
aliases, and unpartitioned console assignments; those are unsafe inputs for a
guest-console route.

This change adds the smallest safe provider-native slice: text terminals for
LXC and serial-capable QEMU guests. It does not treat a Proxmox guest console
as SSH, does not make the browser a Proxmox client, and does not enable
graphical QEMU consoles.

## Goals

- Let an explicitly authorized operator open an xterm session to a uniquely
  resolved LXC guest or QEMU serial console through one selected edge agent.
- Bind each session to one actor, tenant, partition, guest, cluster, node,
  VMID, guest kind, provider credential rule, route, and bounded policy
  snapshot.
- Keep PVE API credentials, cookies, CSRF material, termproxy tickets, and
  websocket parameters out of browser-visible data, URLs, logs, audit
  payloads, device metadata, and persisted session fields.
- Preserve the existing short-lived browser attach ticket, lifecycle audit,
  idle/absolute timeouts, and route-loss close behavior.
- Fail closed when identity, partition provenance, provider capability,
  certificate trust, or terminal compatibility is missing.

## Non-Goals

- Graphical QEMU VNC/noVNC/SPICE/RFB, framebuffer relay, clipboard, drive,
  audio, printer, or smart-card redirection.
- Windows desktop access; that remains owned by the separately gated RDP
  adapter and its NLA/TLS/live-demo proof.
- PVE management actions such as power, migration, configuration, snapshots,
  or arbitrary API proxying.
- Guessing a PVE from duplicate hostnames, VMIDs, aliases, or inventory
  metadata; guest identity ambiguity is an admission failure.
- Stored guest credentials or a shared guest administrator identity. The
  operator authenticates within the console under the guest's own policy.

## Decisions

### 1. Terminal-only provider contract

The first adapter SHALL use the documented Proxmox terminal-console flow
(`termproxy` plus the corresponding ticketed websocket/terminal endpoint) for
LXC and QEMU serial terminals. The agent validates the exact provider response
shape and opens the provider websocket itself. It converts only bounded
terminal data, resize, heartbeat, close, and error frames into the existing
remote-access tunnel.

QEMU guests without an enabled/working serial terminal and guests whose PVE
does not advertise a compatible terminal path SHALL return `guest_terminal_unavailable`.
They SHALL NOT fall back to a graphical VNC/RFB path. LXC and QEMU are kept as
separate typed target kinds because their Proxmox endpoint and console behavior
can differ.

### 2. Identity and route admission before credentials

The control plane constructs a trusted guest-console target snapshot only from
the provider-neutral virtualization read model. It MUST contain one canonical
guest device ID, cluster ID, node ID/name, VMID, and guest kind. Admission
rejects an unresolved alias, duplicate candidate, missing canonical device
link, stale/enabled-false inventory, or a target outside the selected agent's
partition-bound console assignment.

The UI never submits a host, node, VMID, PVE URL, port, agent, or credential
rule. Those values are selected by policy and copied into the signed/session-
bound broker request only after authorization succeeds.

### 3. Provider credential and ticket custody

The control plane resolves a least-privilege Proxmox console credential only
after all session admission checks. The selected agent receives a one-session,
short-lived broker grant bound to the session and target snapshot. It uses that
grant to request a provider console ticket, then clears both the grant and
ticket on close, timeout, route loss, or failure.

The connector must use the deployment's configured PVE TLS trust policy and
reject a name/CA mismatch. It MUST not disable verification merely to make a
console work. Token/cookie/CSRF details remain adapter-private and are never
represented in browser or audit messages.

The console is equivalent to physical provider console access: its PVE
authentication identifies ServiceRadar to Proxmox, not the individual inside
the guest. The audit record therefore records the ServiceRadar actor and
provider-console custody mode, while the guest login remains independent.

### 4. Policy, UI, and auditing

Existing explicit Proxmox-console authorization is required in addition to
device visibility. Device details render a guest-terminal action only for a
safe, supported target; an authorized operator receives a non-secret reason
when policy or capability makes it unavailable. A user without console
permission receives no target or credential detail.

Session audit events include actor, session, canonical guest device, cluster,
node, VMID, guest kind, selected agent/partition, credential-rule reference,
policy outcome, timestamps, byte counters, and normalized close reason. They
exclude terminal bytes, guest credentials, PVE secrets, cookies, tickets, and
websocket URLs.

### 5. Rollout discipline

The feature remains disabled until the current release is deployed, legacy
assignments have been deliberately recovered through the partition-reapproval
flow, and a read-only Proxmox inventory canary proves unique guest identity for
each cluster. Farm01 and Tonka01 must be represented by distinct cluster and
agent/credential tuples even where hostnames overlap.

The first live validation uses dedicated non-production LXC and serial-enabled
QEMU guests. It does not use the Windows VM or expose graphical-console
actions. A failed canary disables only the adapter/assignment and closes active
sessions; it never weakens TLS, identity, or partition checks.

## Risks and Trade-offs

- Provider-console access is powerful and may bypass guest SSH policy. Mitigate
  with separate RBAC, strict target identity, bounded lifetime, audit, and no
  bulk enablement.
- Proxmox versions and authentication modes vary. Mitigate with versioned
  contract fixtures, capability probes, and one supported terminal flow before
  broadening compatibility.
- A ticketed provider websocket can leak if forwarded to a browser. Mitigate by
  terminating it only in the selected agent and relaying typed terminal frames.
- Inventory ambiguity can route a console to the wrong guest. Mitigate by
  failing closed instead of resolving duplicate VMIDs/names from raw metadata.
- QEMU serial availability is not universal. Mitigate with clear unavailable
  outcomes and a separate graphical-console proposal rather than a hidden
  fallback.

## Migration Plan

1. Add the policy/identity and connector contract behind a disabled capability.
2. Add unit and integration fixtures for LXC and serial-QEMU terminal flows.
3. Deploy a signed adapter to one selected agent only.
4. Recover one partition-bound console assignment through the supported UI/API,
   then run a read-only inventory canary per cluster.
5. Enable one dedicated LXC canary, then one serial-QEMU canary; verify audit,
   route loss, ticket expiry, and cleanup.
6. Enable additional explicitly scoped guests only after the canaries pass.

Rollback disables the adapter capability/assignment and closes active sessions.
It does not delete inventory or change PVE configuration.

## Open Questions

- Which exact Proxmox versions and authentication modes are present in Farm01
  and Tonka01, and which documented terminal endpoint variant each supports?
- Which dedicated LXC and serial-enabled QEMU guest can be reserved for the
  first non-production proof?
- Does the current provider credential-rule preset grant only the minimum PVE
  console privilege, or is a new least-privilege role/documented preset needed?
