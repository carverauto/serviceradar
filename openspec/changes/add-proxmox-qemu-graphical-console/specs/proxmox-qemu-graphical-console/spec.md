## ADDED Requirements

### Requirement: QEMU graphical sessions use an authoritative parent PVE target
The system SHALL create a Proxmox QEMU graphical session only from exactly one
active canonical QEMU guest, immutable provider instance, provider-scoped guest
reference, parent PVE host, node, positive VMID, registered PVE HTTPS endpoint
and trust policy, selected agent/gateway route, and explicit session-scoped
console grant. The canonical guest SHALL remain the audited target while the
parent PVE is the network upstream.

#### Scenario: IP-less QEMU guest is unambiguous
- **GIVEN** a canonical QEMU guest has one current provider-instance/node/VMID
  relationship and parent PVE route but no guest IP
- **WHEN** an authorized actor creates a graphical console session
- **THEN** the system SHALL target the registered parent PVE without inventing
  or requiring a guest IP
- **AND** SHALL bind the session and audit outcome to the canonical guest

#### Scenario: Guest identity or placement is ambiguous
- **WHEN** the canonical guest resolves to multiple active provider instances,
  parent hosts, nodes, guest types, or VMIDs
- **THEN** QEMU graphical readiness SHALL fail closed with a sanitized
  identity reason
- **AND** the system SHALL NOT choose a target by display name, address,
  recency, or browser input

#### Scenario: VM placement changes after proof
- **WHEN** the guest migrates to another node or its provider/parent identity
  revision changes
- **THEN** existing target proof SHALL become stale
- **AND** a new session SHALL require freshly resolved and proved placement

#### Scenario: Browser attempts to override the target
- **WHEN** a browser supplies a PVE origin, node, VMID, provider reference,
  agent, gateway, route, console credential, trust mode, quota, or recording
  policy different from server-derived state
- **THEN** the system SHALL reject the request before credential resolution or
  PVE egress

### Requirement: PVE graphical bootstrap is TLS-verified and path-bound
The selected edge adapter SHALL obtain a QEMU proxy ticket and open its
WebSocket only on the registered PVE HTTPS/WSS origin, using verified CA/server
identity and the exact escaped
`/nodes/{node}/qemu/{vmid}/vncproxy` and
`/nodes/{node}/qemu/{vmid}/vncwebsocket` paths. It MUST NOT follow redirects,
use cleartext HTTP/WS, or qualify as ready with insecure TLS verification.

#### Scenario: Authorized PVE graphical bootstrap
- **GIVEN** one authorized session grant is bound to a ready QEMU target and
  selected edge route
- **WHEN** the adapter opens the graphical console
- **THEN** it SHALL call the exact registered QEMU proxy and WebSocket paths
  through verified PVE TLS
- **AND** SHALL use the returned bounded ticket only for that session

#### Scenario: PVE path or origin differs from target state
- **WHEN** a proxy response, redirect, request field, or adapter input attempts
  an alternate origin, node, VMID, path, scheme, port, CA, or server name
- **THEN** the adapter SHALL fail before opening the alternate connection

#### Scenario: PVE TLS is not verifiable
- **WHEN** the registered CA/server identity is missing, invalid, mismatched, or
  configured only for insecure verification
- **THEN** QEMU graphical target readiness SHALL be false
- **AND** the adapter SHALL NOT fall back to insecure TLS

#### Scenario: PVE returns a sensitive error
- **WHEN** proxy or WebSocket bootstrap fails with a URL, Authorization header,
  ticket, cookie, CSRF value, credential fragment, or response body
- **THEN** browser, audit, recording, and proof output SHALL contain only a
  typed redacted failure
- **AND** no complete credential-bearing upstream URL SHALL leave the selected
  edge adapter

### Requirement: The QEMU RFB dependency boundary is reviewed and attestable
The initial QEMU graphical artifact SHALL use a ServiceRadar-owned RFB parser
and SHALL NOT import a third-party RFB/noVNC/browser decoder or copied or
translated remote-access implementation. Its exact direct/transitive
dependencies, versions, features, source origins, licenses, vulnerabilities,
lockfile/Bazel changes, and generated SBOM SHALL be reviewed and bound to the
signed artifact digest before capability advertisement.

#### Scenario: Initial parser artifact is built
- **WHEN** the QEMU graphical artifact is produced
- **THEN** CI SHALL record the reviewed dependency and license inventory,
  vulnerability result, SBOM, artifact digest, and signature
- **AND** the artifact SHALL remain unready when that evidence is absent or
  mismatched

#### Scenario: A new RFB or compression dependency is proposed
- **WHEN** a change adds a third-party parser, compressed encoding library,
  browser decoder, or material dependency feature
- **THEN** CI SHALL reject enablement until an updated security, license,
  vulnerability, lockfile, and SBOM review is approved

#### Scenario: An incompatible source path is detected
- **WHEN** dependency analysis finds an unapproved AGPL/GPL or otherwise
  incompatible source/import path, or copied/translated Teleport/noVNC code
- **THEN** the build SHALL fail and the QEMU graphical capability SHALL remain
  unavailable

### Requirement: RFB parsing is incremental, allowlisted, bounded, and fuzzed
The selected edge adapter SHALL parse RFB as an incremental checked state
machine independent of WebSocket message boundaries. It SHALL accept only the
reviewed PVE RFB 3.8 security profile, canonical pixel format, Raw, CopyRect,
Hextile, DesktopSize, and approved cursor pseudo-encoding. Unknown or
unreviewed versions, security types, messages, pixel formats, encodings,
extensions, and state transitions MUST fail closed.

#### Scenario: Valid RFB messages are arbitrarily fragmented
- **WHEN** a valid handshake or framebuffer update is divided across arbitrary
  WebSocket reads or multiple messages share one read
- **THEN** the parser SHALL produce the same typed result as the unfragmented
  input without reading past available bytes

#### Scenario: Server sends an unsupported encoding
- **WHEN** PVE sends Tight, ZRLE, zlib, vendor, unknown, or another unreviewed
  encoding
- **THEN** the adapter SHALL close with a typed protocol error
- **AND** SHALL NOT pass the bytes through as media or terminal data

#### Scenario: Length or rectangle arithmetic is malicious
- **WHEN** an RFB length, dimension, rectangle count, coordinate, cursor mask,
  tile, multiplication, offset, or trailing-data condition exceeds a checked
  bound or overflows
- **THEN** the parser SHALL reject it before allocation, copy, rendering, or
  input effects

#### Scenario: Clipboard protocol is attempted
- **WHEN** PVE sends server-cut-text or a browser attempts client-cut-text
- **THEN** the adapter SHALL deny the message without forwarding clipboard
  content or enabling a redirection channel

#### Scenario: Parser corpus and fuzzing run in CI
- **WHEN** parser validation runs
- **THEN** deterministic chunk-boundary and malformed corpora plus bounded fuzz
  tests SHALL cover negotiation, initialization, updates, supported encodings,
  cursor/resize, truncation, oversized values, and state sequences
- **AND** every input SHALL terminate as a bounded typed result or error without
  panic, uncontrolled CPU/allocation, or raw-byte disclosure

### Requirement: Raw RFB is translated into existing desktop media and control
Raw PVE RFB bytes SHALL exist only between the verified edge WebSocket and the
edge parser. The adapter SHALL convert validated pixels and cursor updates into
the existing route-bound SRDP desktop-media contract and SHALL convert approved
desktop control messages into bounded RFB input. Raw RFB/VNC bytes MUST NOT
enter terminal data, `ConsoleFrame` output, xterm, generic control payloads,
core/gateway state, recordings, or browser code.

#### Scenario: QEMU framebuffer update is accepted
- **WHEN** the parser accepts a framebuffer rectangle or cursor update
- **THEN** the adapter SHALL emit canonical `rgba8888` dirty-rectangle/tile or
  cursor SRDP frames with session/media binding, sequence, dimensions,
  encoding, metadata, flags, and bounded chunks
- **AND** the existing desktop media path SHALL carry those frames outside the
  generic agent control stream

#### Scenario: Browser sends approved input
- **WHEN** an authorized attached browser sends bounded keyboard, pointer,
  focus, quality, pause/resume, or close control
- **THEN** the selected route SHALL deliver a typed control message to the
  adapter
- **AND** the adapter SHALL map only approved key symbols, coordinates,
  buttons, and operations into RFB client input

#### Scenario: Compatibility code attempts terminal forwarding
- **WHEN** a QEMU graphical adapter or bridge attempts to emit raw WebSocket/RFB
  bytes as terminal data or select an xterm renderer
- **THEN** the boundary SHALL reject the output and terminate the session
- **AND** SHALL NOT fall back to the legacy compatibility path

#### Scenario: Resize is not negotiated
- **WHEN** the browser requests resize but the proved PVE/RFB profile or screen
  policy does not allow it
- **THEN** the adapter SHALL return a typed unsupported result without changing
  target, framebuffer allocation, or session policy

### Requirement: QEMU graphical media and input are resource bounded
The QEMU graphical path SHALL enforce compiled hard maxima and the lower
effective session policy for display dimensions, decoded framebuffer bytes,
rectangle count/area, message and media chunk sizes, queued bytes/frames, frame
rate, bitrate, byte credit, input rate/token size, concurrent sessions,
negotiation, idle time, and absolute duration. It SHALL keep screen media off
the generic agent control stream.

#### Scenario: Frame burst exceeds downstream credit
- **WHEN** PVE produces updates faster than gateway/browser credit is returned
- **THEN** the agent SHALL pause new update requests or bounded reading, coalesce
  or drop stale replaceable updates, and preserve close/control progress
- **AND** SHALL NOT grow queues or block unrelated agent control traffic

#### Scenario: Display or framebuffer exceeds policy
- **WHEN** ServerInit or DesktopSize exceeds the allowed dimensions, pixel
  count, or framebuffer bytes
- **THEN** the adapter SHALL reject it before framebuffer allocation

#### Scenario: Input flood exceeds policy
- **WHEN** browser keyboard or pointer messages exceed input rate, token,
  coordinate, button, or queue limits
- **THEN** the adapter SHALL drop or close according to policy without sending
  unbounded input to PVE

#### Scenario: Agent session capacity is exhausted
- **WHEN** the selected agent has reached its allowed QEMU graphical session or
  memory budget
- **THEN** readiness/open SHALL fail with a sanitized capacity reason
- **AND** the system SHALL NOT route the session to a browser-selected agent

### Requirement: The browser uses the existing protocol-neutral graphical renderer
web-ng SHALL render QEMU graphical sessions through the existing SRDP
WebRTC/DataChannel desktop component with bounded WebGPU-preferred and Canvas
compatibility paths. Browser code SHALL receive only protocol-neutral media,
typed control/status, target labels, and policy state; it MUST NOT receive PVE
credentials, tickets, upstream URLs, raw RFB, or a browser RFB/noVNC connection.

#### Scenario: Browser renders a QEMU console
- **WHEN** current QEMU readiness permits an authorized session and SRDP frames
  arrive
- **THEN** the graphical component SHALL render full/incremental pixels and
  cursor state, show canonical guest/parent identity and policy status, and
  return bounded input/backpressure controls

#### Scenario: Browser lacks the preferred renderer
- **WHEN** WebGPU is unavailable but the bounded Canvas compatibility renderer
  supports the proved SRDP encoding and policy
- **THEN** the same protocol-neutral session MAY render with Canvas
- **AND** it SHALL NOT fall back to xterm, raw RFB, noVNC, or direct PVE access

#### Scenario: Media frame binding is invalid
- **WHEN** a frame has the wrong session/media/route binding, sequence,
  dimensions, payload family, encoding, metadata length, or flags
- **THEN** the browser/gateway media boundary SHALL reject it before rendering
  or lifecycle mutation

### Requirement: Every QEMU graphical exit releases resources and secrets
The system SHALL make normal close, authentication failure, PVE/RFB/media
error, quota exhaustion, route loss, revocation, timeout, browser loss, adapter
crash, agent shutdown, and orphan reaping converge on one idempotent terminal cleanup. Cleanup
SHALL close PVE and media resources, revoke/release grants and tickets, cancel
work, free capacity and parser/framebuffer/queue state, clear owned secret
buffers/references, and record only metadata with a typed redacted outcome.

#### Scenario: Route is lost during a graphical session
- **WHEN** the selected authenticated agent/gateway route disconnects
- **THEN** the PVE WebSocket and desktop-media session SHALL close, credentials
  and tickets SHALL be released, and the generic session SHALL reach a
  route-loss terminal outcome

#### Scenario: Parser fails after credentials are resolved
- **WHEN** malformed RFB causes a protocol failure after PVE authentication
- **THEN** the same idempotent cleanup SHALL run before the session is terminal
- **AND** the public failure SHALL not contain RFB bytes or PVE secrets

#### Scenario: Session never becomes active
- **WHEN** an attached/opening session misses its negotiation or media deadline
- **THEN** a reaper SHALL close it, revoke grants/tickets, release adapter/media
  capacity, and persist the sanitized terminal outcome

#### Scenario: Close is repeated
- **WHEN** browser close, route loss, and adapter exit race for the same session
- **THEN** cleanup SHALL execute effects at most once and subsequent closes
  SHALL be safe no-ops

### Requirement: QEMU graphical readiness requires current deployed proof
The agent SHALL advertise
`remote_access.proxmox.qemu_graphical.rfb_v1` only after applied secure-off
policy, compatible signed artifact and accepted SBOM, graphical bridge/media
contract, RFB parser self-test, and local capacity are healthy. A target SHALL
remain unavailable until its identity/placement, PVE trust, route, console
custody policy, actor authorization/approval, browser renderer, quotas,
recording policy, and exact deployed graphical proof are current.

#### Scenario: Code compiles without a live proof
- **WHEN** the parser and bridge compile and mocked tests pass but no current
  deployed target proof exists
- **THEN** the local capability MAY report adapter health
- **AND** the QEMU target action SHALL remain unavailable

#### Scenario: Controlled fixture passes the deployed proof
- **WHEN** the immutable provider identity behind display tuple
  `farm01 / pve01 / qemu / 155` passes verified PVE auth/TLS, RFB negotiation,
  full and incremental rendering, cursor, keyboard/pointer input,
  backpressure, route-loss, timeout/reaper cleanup, and non-disclosure through
  browser -> web-ng -> core -> gateway -> selected agent -> PVE
- **THEN** that exact target/build/route/trust/policy combination MAY become
  ready while all other QEMU targets remain secure-off

#### Scenario: A proof dependency changes
- **WHEN** feature policy, identity, VM placement, endpoint/TLS, route,
  credential policy, artifact/SBOM/parser/bridge/media/renderer build, quota,
  authorization/approval, recording policy, later probe result, or freshness
  changes
- **THEN** the evidence SHALL become stale and readiness SHALL remain false
  until the required proof succeeds again

### Requirement: QEMU graphical ownership remains separate from terminals and RDP
The QEMU graphical adapter SHALL handle only graphical QEMU
`vncproxy`/`vncwebsocket` sessions. It SHALL NOT handle PVE node terminals, LXC
terminals, QEMU serial terminals, SSH, RDP, Windows target policy, NLA/CredSSP,
or RDP live proof.

#### Scenario: PVE, LXC, or QEMU serial terminal is requested
- **WHEN** server policy selects a PVE node shell, LXC `termproxy`, or explicit
  QEMU serial `termproxy`
- **THEN** the terminal-console owner SHALL handle it with typed PTY/xterm
  behavior
- **AND** the QEMU graphical RFB adapter SHALL not be selected

#### Scenario: RDP session is requested
- **WHEN** server policy selects an RDP target
- **THEN** only the `add-remote-access-desktop-rdp` adapter/readiness path SHALL
  handle it
- **AND** QEMU artifact health or proof SHALL neither satisfy nor alter RDP
  readiness
