## Context

The current Proxmox console adapter can create a QEMU `vncproxy`, open the PVE
`vncwebsocket`, and read its byte stream. It then writes those bytes to the same
console bridge used by terminal sessions, so web-ng renders RFB protocol bytes
with xterm. The current target resolver also treats
`proxmox_vncwebsocket` as enabled before the secure-access program's
provider-instance identity, explicit console credential, generic session, and
readiness prerequisites are complete.

The graphical data plane needed to replace that compatibility path already
exists. `desktop_media.proto`, the agent sender, gateway admission/tracking,
core ingress, WebRTC/DataChannel delivery, the SRDP binary envelope, byte
credits, pause/resume, and the web-ng graphical renderer are implemented for
protocol-neutral desktop frames. The RDP change owns completion of its own
protocol helper and proof; it does not own QEMU RFB parsing.

This child is the QEMU-specific bridge between those two boundaries. It is a
program child of `complete-secure-agent-routed-access`, even if that program
proposal and its prerequisite children land through separate branches.

## Goals / Non-Goals

### Goals

- Open graphical QEMU consoles only through the authoritative parent PVE and
  selected edge route.
- Keep PVE credentials, tickets, WebSocket authentication, and raw RFB entirely
  inside the selected edge adapter boundary.
- Parse an intentionally small RFB subset with strict state, allocation, CPU,
  message, and output bounds.
- Reuse the existing desktop-media/control path and graphical renderer without
  creating a second browser protocol or transport.
- Make capability and target readiness truthful, independently revocable, and
  dependent on a current deployed proof.
- Guarantee terminal cleanup and secret disposal on every exit path.

### Non-Goals

- PVE node, LXC, or QEMU serial terminals and any xterm behavior.
- RDP adapter/helper work, Windows target policy, NLA/CredSSP, or RDP proof.
- Arbitrary VNC targets, direct browser-to-PVE connectivity, noVNC in the
  browser, SPICE, a binary WebSocket media fallback, or a general TCP proxy.
- Proxmox provider-identity migration, generic console-rule management, or the
  generic remote-access/readiness state machine beyond QEMU integration.
- Clipboard, file transfer, audio, USB/device redirection, power/configuration
  actions, or framebuffer-content recording.

## Prerequisites and Ownership

Implementation and live proof wait for these program prerequisites:

1. Reconciled canonical remote-access specifications and the authoritative
   readiness evidence contract.
2. Immutable provider-instance-scoped Proxmox host/guest identity with legacy
   collisions migrated or quarantined.
3. A generic Proxmox console target that resolves exactly one QEMU guest,
   parent PVE node, registered HTTPS endpoint/trust policy, selected agent and
   gateway, and explicit `console_access` credential grant.
4. Generic remote-access attach, authorization, authenticated return-route,
   timeout, revocation, audit, metadata recording, and reaper guarantees.
5. Compatible deployed desktop-media and web renderer builds.

This child consumes those contracts. It owns only the QEMU graphical adapter,
its dependency and security review, its RFB/media/control behavior, its QEMU
readiness integration, and its proof.

## Architecture

```text
browser graphical component
  -> existing WebRTC desktop-media/control session
  -> web-ng/core generic remote-access session
  -> authenticated gateway route
  -> selected Go agent and graphical plugin bridge
  -> Proxmox console adapter (RFB parser and translator)
  -> verified parent PVE HTTPS vncproxy + WSS vncwebsocket
  -> exact provider instance / node / QEMU VMID
```

The canonical QEMU guest remains the audited target. The parent PVE endpoint is
only the trusted network upstream. No browser field can substitute either one.

## Decisions

### Decision: Resolve and freeze the parent PVE target before opening media

Session creation consumes the prerequisite target resolver result containing:

- canonical guest device UID and identity revision;
- immutable Proxmox provider-instance ID;
- provider-scoped guest and parent-host references;
- guest type `qemu`, exact node, and positive VMID;
- registered PVE HTTPS base URL, CA policy, and server name;
- selected agent, gateway, route/affinity revision;
- explicit console custody/policy reference and session grant;
- screen, input, timeout, recording, approval, and actor policy.

Every value is server-derived. The adapter compares the session target digest
with the open command and authenticated route before any credential lookup or
PVE request. A missing, stale, multiple, migrated, or mismatched relationship
fails closed. VM migration invalidates readiness; a later session must resolve
and prove the new parent node rather than following an untrusted redirect.

### Decision: Authenticate PVE at the edge with an exact egress allowlist

The selected edge adapter performs only:

```text
POST /api2/json/nodes/{node}/qemu/{vmid}/vncproxy
GET  /api2/json/nodes/{node}/qemu/{vmid}/vncwebsocket
```

It uses the registered PVE origin and exact escaped node/VMID. Redirects,
alternate origins, browser-supplied paths, cleartext HTTP/WS, IP/server-name
overrides, and readiness with `insecure_skip_verify` are denied. Both calls use
the registered CA/server identity. The implementation bounds and validates the
proxy JSON, port, ticket, user, and expiry fields before constructing WSS.

The API credential grant and returned ticket exist only in the selected
session adapter. A ticket may be present in the upstream PVE WebSocket query as
required by PVE, but the complete URL is never logged, audited, recorded,
returned to core, or sent to the browser. Authorization headers, cookies, CSRF
values, tickets, and response bodies are redacted structurally.

### Decision: Use a ServiceRadar-owned minimal RFB parser

The first production slice adds no external RFB client, noVNC package, browser
VNC decoder, or copied/translated VNC implementation. A ServiceRadar-owned Go
streaming parser lives inside the existing first-party Proxmox graphical
adapter boundary and is compiled into its isolated Wasm artifact. Native Go
tests exercise the same parser package for fuzzing and sanitizers available in
CI.

The parser uses only the existing ServiceRadar SDK HTTP/WebSocket host surface
and standard project dependencies. This keeps the initial dependency delta
small and makes the untrusted protocol boundary reviewable. Before code lands,
the implementation PR records:

- exact direct/transitive modules, versions, features, Bazel repositories, and
  lockfile changes for the Proxmox artifact and graphical bridge;
- licenses and source origins, with AGPL/GPL or otherwise incompatible paths
  rejected and no Teleport/noVNC source copied or translated;
- vulnerability/advisory results and accepted exceptions with owners/expiry;
- generated SBOM entries for the Wasm artifact and any host-side bridge code;
- proof that the shipped artifact digest/signature matches the reviewed SBOM.

Any later third-party RFB parser, compressed encoding library, or browser
decoder is a material dependency-boundary change and requires an updated
license/security review before enablement.

### Decision: Negotiate a narrow RFB profile and reject everything else

The initial adapter supports RFB 3.8 and only the security negotiation observed
and recorded for the controlled authenticated PVE `vncwebsocket`. It may accept
PVE's `None` security type only when authentication is already bound to the
verified WSS ticketed session, or the observed ticket-backed VNC challenge
flow. It never falls back across security types after a failure and rejects
unknown/downgraded versions or security results.

After `ServerInit`, the client requests one canonical 32-bit pixel format and a
small encoding allowlist:

- Raw;
- CopyRect;
- Hextile;
- DesktopSize;
- cursor pseudo-encoding required by the fixture.

Tight, ZRLE, zlib, RRE, CoRRE, JPEG, H.264, vendor encodings, clipboard
messages, file-transfer extensions, and unknown pseudo-encodings are not
negotiated in this slice. If the server sends one anyway, the session closes
with a typed protocol error. Adding a compressed or vendor encoding requires a
separate delta review of decompression limits, dependency/SBOM impact, and
fuzzing.

The parser is an incremental state machine. It never assumes one WebSocket
message equals one RFB message and never allocates from an unvalidated length.
Arithmetic uses checked bounds before multiplication or offset advancement.
Trailing bytes, impossible transitions, overlapping/truncated rectangles,
invalid pixel formats, invalid cursor masks, and post-close data fail closed.

### Decision: Translate at the edge into existing desktop contracts

The adapter converts accepted server pixels into canonical `rgba8888`
dirty-rectangle/tile payloads and cursor updates. The agent wraps those in the
existing SRDP envelope with the QEMU session/media binding, sequence,
dimensions, timestamp, payload family, encoding, metadata, and flags. Large
rectangles are tiled or chunked within existing desktop-media limits; they are
not buffered into one control-stream frame.

The browser reuses `RemoteAccessDesktopSession` and its SRDP parser/render
queue. WebGPU remains preferred and the existing Canvas2D path remains the
compatibility renderer. The UI labels the protocol as Proxmox QEMU graphical
console and shows the canonical guest, parent PVE, recording policy, connection
state, and sanitized readiness reason. It never imports an RFB parser.

Typed keyboard, pointer, focus, quality, pause/resume, and close controls flow
through the existing desktop control path. The edge adapter maps only bounded
allowlisted key symbols and pointer buttons into RFB client messages. Resize is
accepted only when the negotiated PVE/RFB capability and screen policy support
it; otherwise it returns a typed unsupported response without changing the
session target. Clipboard and client-cut-text are always denied.

Raw RFB bytes exist only between the verified PVE WebSocket and the edge parser.
They MUST NOT be emitted through `ConsoleFrame` terminal data, xterm, generic
control frames, PubSub, ERTS RPC, recordings, desktop-media payloads, or browser
code.

### Decision: Apply limits at every boundary

Every configurable value is capped by a compiled hard maximum. The effective
limit is the minimum of the shared desktop policy, QEMU policy, agent capacity,
gateway admission, and browser capability. The initial production profile is
no broader than:

| Boundary | Initial maximum |
| --- | --- |
| Display | 3840 x 2160, 32-bit, 32 MiB decoded framebuffer |
| Framebuffer update | 256 rectangles and checked region area |
| Normalized media chunk | 256 KiB |
| Outstanding media credit | 4 MiB |
| Edge queued RFB/SRDP bytes | 4 MiB per session |
| Browser render queue | 12 frames with stale update coalescing/drop |
| Frame rate / bitrate | 30 fps / 32 Mbit/s hard QEMU ceiling |
| Input | 120 events/s sustained with a bounded burst and 128-byte key token |
| Concurrent QEMU consoles | 2 per agent by default, lower under policy |
| Negotiation / idle / absolute | 15 s / 15 min / 1 h maximum defaults |

The parser streams raw/hextile pixels into bounded tiles instead of retaining a
second full update. CopyRect source/destination regions must lie inside the
current framebuffer. DesktopSize above policy is rejected before allocation.
Credit exhaustion pauses RFB update requests and reads only the bounded amount
needed for protocol progress; it never grows queues. A deadline closes a peer
that continues to violate flow control or cannot make progress.

### Decision: Capability and readiness require current proof

The agent advertises
`remote_access.proxmox.qemu_graphical.rfb_v1` only when applied policy enables
it and the signed Proxmox artifact, accepted SBOM, graphical bridge version,
RFB parser self-test, desktop-media client, and local capacity are compatible
and healthy.

Target readiness additionally requires the current unambiguous guest/parent
relationship, registered verified PVE endpoint, exact route, explicit console
grant policy, actor authorization/approval, renderer/media contract build, and
a fresh target proof. Create and attach re-evaluate those dependencies
atomically. A feature, identity, VM placement, endpoint/TLS, route, credential
policy, artifact/parser/bridge/media/renderer build, quota, authorization,
recording policy, failed later probe, or freshness change invalidates proof.

The controlled live fixture is the display tuple
`farm01 / pve01 / qemu / 155`. Before proof, the implementation resolves and
records its immutable provider-instance ID and canonical guest/host UIDs. A
changed or ambiguous tuple is a blocker, not a reason to choose by display
name. The proof must exercise verified PVE TLS, vncproxy/WSS authentication,
RFB negotiation, first full frame, incremental update, cursor, keyboard and
pointer input, credit pause/resume, route loss, timeout/reaper cleanup, and
secret/raw-RFB non-disclosure through the deployed browser path.

### Decision: Cleanup is one idempotent terminal operation

Open/attach/negotiation/media deadlines and generic session reapers all call one
idempotent close path. It:

1. stops new browser input and RFB update requests;
2. closes the PVE WebSocket and graphical plugin bridge;
3. closes the desktop-media session even when media credit is zero;
4. revokes/releases the credential grant and PVE proxy ticket;
5. overwrites owned mutable credential/ticket and parser/frame buffers where
   supported, clears references, and drops framebuffer/queue state;
6. cancels timers/workers and frees Wasm/session capacity;
7. transitions the generic session to one bounded terminal outcome; and
8. emits metadata-only audit/proof data with a typed redacted reason.

Duplicate close, route loss, adapter crash, browser disappearance, auth error,
parser error, quota exhaustion, timeout, revocation, and agent shutdown all use
the same semantics. No terminal failure falls back to the legacy raw-xterm
path.

## Threat Model

### Assets

- PVE API credential grant, Authorization header, proxy ticket, cookies/CSRF,
  and verified endpoint policy.
- Canonical QEMU guest/parent identity and the operator's authorized input.
- Framebuffer/cursor contents and metadata recording policy.
- Agent/gateway/control-plane availability and unrelated control-stream work.

### Trust Boundaries

- Browser to authenticated web-ng WebRTC/control session.
- Core to gateway to selected agent authenticated route.
- Agent to isolated Proxmox graphical adapter/SDK host ABI.
- Adapter to verified parent PVE HTTPS/WSS endpoint.
- Untrusted RFB bytes to the streaming parser and normalized SRDP output.

### Abuse Cases and Mitigations

- Malformed RFB causes panic, allocation, decompression, or CPU exhaustion:
  minimal encoding set, checked incremental parser, hard quotas, Wasm memory
  limit, fuzz/property corpus, deadline, and fail-closed process/session cleanup.
- Browser retargets a privileged PVE request: immutable target digest, exact
  path/origin allowlist, route binding, no redirects, and server-derived values.
- Provider ticket leaks through URL/log/error: edge-only construction,
  structural redaction, no payload logging, secret-surface regression tests,
  bounded lifetime, and disposal.
- Cross-agent or cross-session frame injection: authenticated route and media
  binding, sequence checks, one session grant, and rejection before render,
  lifecycle mutation, recording, or input.
- Stale identity opens the wrong VM after migration/collision: immutable
  provider instance, exact parent/node/VMID, revision-bound evidence, atomic
  create/attach recheck, and proof invalidation.
- Frame flood blocks control traffic: dedicated media stream, byte credit,
  bounded queues, rate/bitrate caps, stale-frame drop, and per-agent admission.
- Malicious media metadata reaches the browser renderer: SRDP schema/length
  validation, canonical pixel encoding, render dimension checks, no raw RFB,
  browser queue bounds, and no dynamic code/HTML interpretation.
- Revocation or route loss leaves credentials/processes alive: one idempotent
  terminal close path and reaper with explicit resource/secret assertions.

## Risks / Trade-offs

- A project-owned parser avoids an opaque or browser-side RFB dependency but
  makes ServiceRadar responsible for protocol correctness. The narrow encoding
  set, state-machine review, fuzzing, and exact PVE fixture contain that scope.
- Excluding Tight/ZRLE may use more bandwidth. The first goal is a bounded
  administrative console and proof; compressed encodings require their own
  decompression and dependency review.
- Wasm isolation limits parser blast radius but requires a typed graphical SDK
  bridge. That bridge is intentionally QEMU-agnostic and may carry only
  protocol-neutral desktop frames/control, not PVE credentials or raw RFB.
- The exact live fixture may migrate or be unavailable. Readiness remains false
  until its current provider-instance/node/VMID relation is re-resolved and a
  replacement fixture is explicitly approved in this change rather than chosen
  heuristically.

## Migration and Rollout

1. Land the program prerequisites and keep QEMU graphical policy/capability off.
2. Land the parser, typed graphical bridge, media/control translation, browser
   integration, and cleanup behind the secure-off gate. Remove any path that can
   expose QEMU RFB as terminal data before advertising the capability.
3. Complete dependency/license/vulnerability/SBOM review, deterministic tests,
   fuzzing, static analysis, artifact signing, and parser self-test.
4. Pass local and integration denial/resource/lifecycle tests without PVE
   credentials or live mutation.
5. Resolve the current immutable identity for the controlled QEMU 155 fixture
   and run the approved read-only/session-scoped deployed graphical proof.
6. Enable only that canary target with current evidence, observe resource and
   cleanup telemetry, then expand only through separately approved target
   proofs. Keep defaults off.

Rollback disables the QEMU graphical policy/capability, rejects new sessions,
closes active sessions through the terminal cleanup path, revokes outstanding
grants/tickets, and leaves inventory, PVE/LXC/QEMU serial terminals, SSH, and
RDP unchanged.

## Open Questions

- Record the controlled PVE fixture's exact RFB security type, pixel format,
  cursor pseudo-encoding, and server-version behavior before freezing the
  initial negotiation profile. Any behavior outside the reviewed subset keeps
  readiness false.
- Record the immutable provider-instance ID and canonical guest/parent UIDs for
  display tuple `farm01 / pve01 / qemu / 155` after provider identity migration.
