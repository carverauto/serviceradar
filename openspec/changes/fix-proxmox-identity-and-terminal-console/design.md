# Design: Provider-scoped Proxmox identity and terminal consoles

## Context

Proxmox enrichment currently emits provider references such as
`proxmox:node:<node>` and `proxmox:guest:<node>:<type>:<vmid>`. The persistence
identity is provider plus provider reference, so equal node names or VMIDs from
independent provider instances can overwrite one another. A cluster display
name appears in some integration identifiers, but display names are mutable and
are not a sufficient namespace.

The existing console implementation has useful pieces but does not provide one
safe end-to-end contract. The target resolver can choose the first matching
virtualization row and fall back to metadata. Native provider sessions can use
an `inventory_enrichment` API token, and the browser may submit a credential
rule. Guest routes are derived from the guest device rather than the parent PVE
endpoint. A provider-specific session table/broker bypasses parts of the generic
remote-access lifecycle. QEMU graphical VNC and PTY modes are also mixed in a
terminal-shaped interface.

This design makes identity migration a prerequisite for any new terminal
action. It then adapts Proxmox terminal setup into the existing generic session
and broker rather than maintaining a second trust path.

## Invariants

1. A Proxmox provider instance has one immutable internal reference that is not
   derived solely from mutable provider labels or discovered resources.
2. Every Proxmox host, guest, relationship, console target, credential rule,
   grant, readiness result, and session is bound to that provider instance.
3. A canonical guest is the audited/display target, but native terminal traffic
   is sent only to its authoritative parent PVE endpoint on a server-selected
   eligible edge route.
4. Ambiguity causes unavailability or quarantine. First-row selection, name/IP
   heuristics, cross-instance aliases, and browser overrides are forbidden.
5. `console_access` is an interactive purpose boundary. Inventory credentials
   and generic credentials cannot qualify or act as fallback.
6. This child emits and renders only typed PTY terminal traffic. RFB/VNC and RDP
   are never tunneled as terminal bytes.
7. Provider credential material is resolved only after atomic attach, remains
   bounded to one session, and is removed on all success and failure paths.
8. New sessions use generic hardened session/broker guarantees. Compatibility
   code cannot create an alternate provider-specific security path.

## Decisions

### Decision: Register immutable provider instances

Each configured Proxmox integration receives a generated immutable
`provider_instance_ref` at registration. The reference is stored independently
of the cluster display name, node names, endpoints, and credentials. It remains
stable across display-name edits, credential rotation, and endpoint certificate
rotation. Changing ownership to a different PVE estate requires an explicit new
provider instance rather than silently reusing the reference.

Trusted inventory assignments carry this reference into collection and
enrichment. Provider resources use normalized references:

- `proxmox:<provider-instance>:cluster:<native-cluster-id>`
- `proxmox:<provider-instance>:node:<node>`
- `proxmox:<provider-instance>:guest:<node>:<qemu|lxc>:<vmid>`

Datastores, disks, NICs, storage resources, and console targets use the same
namespace. The provider instance is a routing and uniqueness boundary; the
canonical device integration ID remains a separate identity concept.

The provider instance must originate from the trusted assignment/registration
boundary. A collector result cannot declare a different instance, and a browser
cannot submit one. Ingest rejects a missing, unknown, disabled, or mismatched
instance before mutating virtualization state.

### Decision: Migrate proven rows and quarantine ambiguity

The migration starts with a read-only classifier and collision report. For each
legacy provider row it derives candidate instances from trusted assignment
history, source endpoint, integration ownership, and complete relationship
evidence. It never uses a display name, node name, VMID, hostname, or IP alone.

Rows with exactly one proven instance are rewritten transactionally with their
dependent relationships. Rows with zero or multiple proven instances, or with
conflicting host/guest/parent evidence, are marked quarantined and excluded from
console readiness. Their source provider instance must be re-ingested to create
authoritative scoped records. Quarantine records preserve bounded provenance
for operator review but never act as route aliases.

After classification and re-ingestion, the schema enforces non-null provider
instance scope and scoped uniqueness. A legacy reference may remain as an
operator-visible alias only when it resolves inside exactly one provider
instance; it cannot be a routing or authorization key and is disabled if a
second candidate appears.

This ordering prevents the same-name Farm/Tonka case from becoming a silent
last-write-wins migration. Both `pve02` rows and overlapping guest identifiers
must remain distinct, with their own relationships and console targets.

### Decision: The parent PVE is the network upstream

Terminal resolution starts from the canonical display target and requires
exactly one active virtualization row. A guest result freezes:

- provider instance and scoped guest reference;
- guest type and VMID;
- scoped parent host reference and canonical parent PVE device;
- registered PVE endpoint, port, and TLS trust policy;
- selected connected agent/gateway/partition route eligible for that parent;
- terminal adapter mode and policy revision.

The guest device remains the user-visible and audited target. The PVE host is
the network upstream and credential resource. A missing parent, multiple active
parents, a cross-instance relationship, stale moved-guest relationship, or a
route eligible only for the guest makes readiness unavailable. Guest IP is not
required for native provider terminals and is never substituted for the PVE
endpoint.

The adapter constructs an allowlisted PVE API request from these immutable
values. It is not a general PVE HTTP proxy. Allowed setup operations are bounded
to the selected resource and terminal mode:

- PVE node: `/nodes/{node}/termproxy`
- LXC guest: `/nodes/{node}/lxc/{vmid}/termproxy`
- QEMU serial guest: `/nodes/{node}/qemu/{vmid}/termproxy`

The corresponding provider websocket path, ticket, port, cookie, and CSRF
values are derived and consumed inside the agent adapter. Redirects or returned
paths outside the registered endpoint and selected resource are rejected.

### Decision: QEMU is terminal-ready only with an explicit serial console

PVE node and LXC `termproxy` are PTY modes. QEMU `termproxy` is eligible only
when authoritative current provider configuration records an enabled serial
console that policy has registered for ServiceRadar terminal access. A QEMU
type, operating-system label, config name, or provider default does not prove
serial availability.

The adapter emits bounded typed data, input, resize, error, and close frames;
web-ng renders xterm. Any `vncproxy`, `vncwebsocket`, RFB banner, framebuffer
payload, or graphical-only QEMU configuration returns a typed
`terminal_transport_unavailable` result. This child neither interprets nor
forwards graphical bytes. RDP remains outside this adapter and readiness model.

### Decision: Interactive credentials use exact-purpose rules

A Proxmox terminal requires exactly one enabled rule with purpose
`console_access`. Server-side policy resolves it from the frozen provider
instance, PVE resource, endpoint, selected route, actor/session policy, terminal
mode, and required PVE privilege. The browser requests only the ready action for
the target; a submitted credential rule ID or routing/target override is
rejected.

The rule must cover the exact provider instance and resource. It may be narrowed
to node/guest/VMID, endpoint, agent/gateway/partition, terminal operation, API
method/path allowlist, and TTL. PVE node shells require the corresponding
least-privilege console permission such as `Sys.Console`; guest terminals
require the corresponding guest console permission such as `VM.Console`.
Operators may use distinct PVE credentials for inventory and interactive
console. An `inventory_enrichment` or `generic` purpose never qualifies, even
when its secret could technically authenticate to the same endpoint.

Equal-priority matches, broader cross-instance matches, route mismatch, missing
privilege evidence, or a disabled/expired rule yield a typed unavailable result.
There is no trial of multiple secrets.

After atomic browser attach, core creates a one-session broker grant bound to
actor, session, display target, parent PVE resource, provider instance, endpoint,
agent, gateway, protocol, allowed API operations, and expiry. Only the selected
agent may redeem it. Durable add-on assignments and generic command rows carry
references, not decrypted tokens or passwords.

### Decision: Adapt new terminals into the generic hardened broker

The externally visible Proxmox action may retain a compatibility API facade,
but a new open creates a generic `RemoteAccessSession` with protocol
`proxmox_console` and typed terminal transport. The generic broker owns atomic
single-use attach, route authentication, frame integrity and replay protection,
authorization checkpoints, limits, audit, recording policy, terminal outcomes,
and reaping.

The provider adapter begins only after attach is consumed and the selected
route is frozen. It cannot replace the route, target, terminal mode, TLS policy,
credential rule, or endpoint. Return frames bind session ID, route generation,
sequence, target digest, and deadline and use the generic authenticated frame
envelope. Wrong-route, stale-generation, duplicate, late, or integrity-invalid
frames cannot mutate session state, stream output, record data, or report a
successful audit outcome.

The legacy provider-specific session table and broker may support read/close of
sessions created before cutover for a bounded drain interval. They cannot create
new sessions after the migration gate opens. Existing nonterminal rows are
terminalized by a migration/reaper with a typed close reason; no long-lived
`requested` row may survive rollout.

### Decision: Readiness is authoritative and re-evaluated

The applied edge agent advertises
`remote_access.proxmox.terminal_v1` only when terminal policy is enabled and the
local adapter, PVE TLS client, frame protocol, bounded runtime, cleanup, and
self-tests are compatible and healthy. Linking the code or assigning a package
is insufficient.

Device detail readiness intersects:

- the secure-off deployment and provider-terminal policy gates;
- exactly one active scoped provider identity and, for guests, one parent PVE;
- current resource type/VMID and terminal-mode evidence;
- registered PVE endpoint and approved TLS trust;
- one connected parent-eligible route with the applied capability;
- exactly one matching `console_access` rule and required privilege scope;
- actor permission, approval/hold state, adapter/renderer availability, and
  current provider/route proof.

PVE and LXC actions may become ready when their terminal evidence is current.
QEMU actions become ready only for an explicit current serial registration.
Authorized operators can inspect a sanitized typed reason when the action is
unavailable. Session create and attach re-evaluate mutable inputs atomically;
stale client readiness is not authority.

### Decision: Cleanup is a terminal state transition

Provider access material is resolved as late as possible and held only by the
bounded selected-agent session runtime. The adapter minimizes copies and clears
owned mutable buffers and references for API tokens, PVE tickets, cookies, CSRF
values, proxy tickets, and any password material on open failure, close,
authorization revocation, grant expiry, idle/absolute timeout, route loss,
agent restart, duplicate/replay rejection, or normal completion.

Every terminal path closes the provider websocket, revokes the grant, removes
pending agent state, closes the browser stream, records one sanitized terminal
outcome, and lets the generic reaper remove orphaned runtime state. Audit
identifies actor, display target, parent PVE, provider instance, selected route,
mode, policy revisions, start/end time, and close reason but excludes terminal
content and secret values. Recording follows generic policy; provider
credentials and setup frames are never recordable terminal data.

## Failure Contracts

The public/API surface uses stable sanitized classes such as
`identity_ambiguous`, `provider_instance_unavailable`,
`parent_pve_unavailable`, `terminal_transport_unavailable`,
`credential_unavailable`, `credential_conflict`, `route_unavailable`,
`trust_unavailable`, `authorization_denied`, and `session_terminated`. Internal
provider response bodies, endpoints not already visible to the actor, rule IDs,
tokens, tickets, cookies, and route secrets remain private.

## Migration and Rollout

1. Land schema, classifier, scoped emitters, and compatibility reads secure-off.
2. Produce a dry-run collision report and verify Farm/Tonka same-name and
   overlapping-VMID fixtures classify independently.
3. Pause affected enrichment writes, transactionally migrate uniquely proven
   rows, quarantine ambiguous rows, re-ingest each registered provider instance,
   validate relationship counts, and enforce scoped uniqueness.
4. Create and validate separate least-privilege `console_access` rules. Inventory
   continues with inventory-only rules.
5. Land the agent terminal adapter, generic broker integration, capability,
   cleanup, readiness, and device action behind a secure-off gate.
6. Drain and terminalize legacy sessions, then disable new creation through the
   provider-specific broker.
7. Pass automated negative/cleanup tests and approved live proofs for both
   provider instances, including one PVE terminal, one LXC terminal, and one
   explicitly configured QEMU serial terminal when such a fixture is available.
8. Enable only approved canary resources, observe audit/reaper/credential
   behavior, and expand by provider instance.

Rollback disables readiness and new opens, closes active sessions, revokes
grants and provider tickets, and restores the previous application version only
after it is prevented from authorizing interactive access through unscoped or
inventory credentials. Legacy aliases may support bounded inventory reads but
never console routing. Quarantined rows remain quarantined until authoritative
re-ingestion; rollback does not guess identity or enable graphical/RDP paths.

## Risks / Trade-offs

- Some legacy rows may be unavailable until re-ingestion. That is preferable to
  cross-instance overwrite or console routing.
- VM migration can make a previously ready parent relationship stale. Atomic
  create/attach evaluation and route closure favor safety over availability.
- Separate inventory and console credentials add operator setup, but make
  interactive privilege explicit and revocable without breaking discovery.
- PVE terminal tickets and websocket setup are provider-specific. A narrow
  adapter and exact path allowlist prevent that detail from becoming a general
  proxy or a second broker.
- The compatibility drain adds temporary code, but it is bounded and cannot
  create new legacy sessions.

## Open Questions

- Which immutable registration source will seed provider instance references
  for already-configured deployments where assignment history is incomplete?
  The implementation must choose an explicit administrative mapping rather than
  infer from display names.
- Which Farm/Tonka PVE, LXC, and explicit QEMU serial fixtures are approved for
  the live proof? Fixture selection and any serial-console configuration are
  operational changes outside this proposal-only work.
