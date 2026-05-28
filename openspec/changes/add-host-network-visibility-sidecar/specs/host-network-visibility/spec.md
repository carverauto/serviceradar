## ADDED Requirements

### Requirement: Bundled host visibility sidecar binary

ServiceRadar SHALL ship a standalone Rust binary
`serviceradar-netprobe` built from `rust/netprobe/` and bundled inside
the `serviceradar-agent` package (deb, rpm, OCI image, tarball). The
project MUST keep build targets for static musl binaries for
`x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`. Phase 1
shipping Linux artifacts MAY use the default dynamically linked build
while packet capture depends on libpcap; those artifacts MUST declare
or bundle their libpcap and C-runtime dependencies.

#### Scenario: Netprobe binary ships with the agent package
- **WHEN** the agent OCI image, deb, or rpm is built via the Bazel
  packaging targets
- **THEN** `/usr/local/lib/serviceradar/bin/serviceradar-netprobe`
  exists in the artifact
- **AND** deb/rpm metadata declares the libpcap runtime package
- **AND** the OCI runtime filesystem includes the libpcap runtime
  library needed by the packaged binary

#### Scenario: Static musl build target remains available
- **WHEN** `bazel build --platforms=//build/platforms:linux_x86_64_musl //rust/netprobe:netprobe`
  is run
- **THEN** the build produces a static `serviceradar-netprobe` binary
- **AND** the packaging docs mark the musl artifact as a portability
  target until static packet capture support is available

#### Scenario: Sidecar is excluded on non-Linux agent builds
- **WHEN** the agent is packaged for macOS or Windows
- **THEN** the agent package does not include `serviceradar-netprobe`
- **AND** the agent advertises the `host-network-visibility` capability
  as unavailable rather than enabled

### Requirement: Sidecar capabilities scoped to the netprobe binary

`serviceradar-netprobe` SHALL hold `CAP_BPF`, `CAP_PERFMON`, and
`CAP_NET_RAW` via file capabilities (deb/rpm postinst) or Kubernetes
pod `securityContext` for the sidecar process. The `serviceradar-agent`
process MUST NOT gain `CAP_BPF` or `CAP_PERFMON` as a side effect of
introducing the sidecar. The pre-existing agent `CAP_NET_RAW` (used for
ICMP/MTR raw sockets) remains as configured today.

#### Scenario: Agent process does not gain CAP_BPF or CAP_PERFMON
- **WHEN** `serviceradar-agent` is running with `netprobe` supervised on
  a Linux host
- **THEN** `getpcaps $(pidof serviceradar-agent)` shows no `cap_bpf` or
  `cap_perfmon` capability on the agent process
- **AND** `getpcaps` on the `serviceradar-netprobe` PID shows
  `cap_bpf`, `cap_perfmon`, and `cap_net_raw`

### Requirement: Capability sequencing and privilege drop

`serviceradar-netprobe` SHALL acquire its required Linux capabilities at
process start, perform all privileged operations (load eBPF programs,
open pcap handles, pin BPF maps, bind the UDS listener), and then drop
to a non-root UID before serving the UDS or accepting any agent
configuration. Subsequent operations MUST NOT require the original
capability set.

#### Scenario: Capabilities dropped before UDS serves
- **WHEN** the sidecar reaches the point of accepting the first agent
  connection on its UDS
- **THEN** the process is running under a non-root UID
- **AND** `getpcaps` on the process shows the effective capability set
  reduced to the minimum needed for steady-state operation

### Requirement: Capture-interface allowlist with deny-by-default

The sidecar SHALL refuse to open packet capture on any interface not
explicitly listed in `VisibilityAgentConfig.capture_interfaces` and
MUST refuse `any` or wildcard interface names. Refusals MUST be logged
at WARN and counted via
`serviceradar_netprobe_interface_denials_total`.

#### Scenario: Wildcard interface is rejected
- **WHEN** the delivered config contains
  `capture_interfaces: ["any"]`
- **THEN** the sidecar refuses to start capture
- **AND** logs the refusal and increments the denial counter

#### Scenario: New interface requires explicit operator opt-in
- **WHEN** a new network interface appears on the agent host
- **AND** no profile or config update has added it to
  `capture_interfaces`
- **THEN** the sidecar does not capture on the new interface, even for
  flows that would otherwise match profile scope

### Requirement: Passive fingerprinting via huginn-net

`serviceradar-netprobe` SHALL implement passive OS / device
fingerprinting using `huginn-net` for TCP p0f-style analysis, plus
JA4/JA4S extraction for TLS handshakes and minimal header analysis for
HTTP. Each protocol analyzer MUST be independently toggleable from the
per-device binding in `VisibilityAgentConfig`.

#### Scenario: Per-protocol fingerprint toggles honoured
- **WHEN** a device binding enables only `fingerprint.tcp`
- **THEN** the sidecar performs TCP fingerprinting only for that
  device's observed flows
- **AND** does not emit TLS or HTTP fingerprint events for the same
  device IP

#### Scenario: Fingerprint engine version reported in Ping reply
- **WHEN** the agent issues `Ping` to the sidecar
- **THEN** the `PingAck` reply includes the compiled `huginn-net` crate
  version

### Requirement: Deep packet inspection with privacy-by-default

`serviceradar-netprobe` SHALL classify observed flows into application
protocols using a built-in dissector set covering at minimum HTTP/1.x,
HTTP/2 cleartext, TLS SNI, DNS, SSH, FTP, QUIC, MQTT, and BitTorrent.
Each dissector MUST be independently toggleable. Emitted `DpiEvent`
records MUST contain only the 5-tuple, identified protocol, confidence
score, dissector identifier, and observation timestamp.

#### Scenario: DPI event omits payload material
- **WHEN** the sidecar classifies an HTTP/1.1 request bearing a Host
  header, URI, body, and assorted headers
- **THEN** the emitted `DpiEvent` carries the protocol identifier
  (`http`), the 5-tuple, and the confidence score
- **AND** does not carry the URI, request or response body, or the Host
  header value

#### Scenario: Disabled dissectors are not invoked
- **WHEN** the device binding lists `dpi.protocols = ["http"]`
- **THEN** the sidecar applies only the HTTP dissector to that device's
  flows
- **AND** does not invoke TLS-SNI, DNS, or other dissectors for the
  same flows

### Requirement: eBPF-driven per-process flow attribution

`serviceradar-netprobe` SHALL bind locally-observable TCP, UDP, and
QUIC flows to their owning process (PID, command name, redacted command
line, UID, container identifier when resolvable) using eBPF programs
loaded at start-up. Maps MUST be pinned under
`/sys/fs/bpf/serviceradar/netprobe/` so a sidecar restart can reattach
to existing programs without losing in-flight state.

#### Scenario: TCP connect resolves to PID and process attribution
- **WHEN** a process on the host opens a TCP connection
- **THEN** the sidecar emits a `FlowAttributionEvent` whose `pid`,
  `comm`, `uid`, and (when applicable) `container_id` correspond to the
  owning process

#### Scenario: Sidecar restart reattaches to pinned maps
- **WHEN** the sidecar is restarted while flows are active
- **THEN** the new sidecar instance reattaches to the pinned BPF maps
- **AND** continues emitting attribution events for flows that began
  before the restart

### Requirement: Degraded mode on kernels without modern BPF support

`serviceradar-netprobe` SHALL refuse to load eBPF features on Linux
kernels that lack the `CAP_BPF` / `CAP_PERFMON` split or whose
verifier rejects the eBPF programs, continue serving fingerprinting
and DPI in that condition, and report the degradation through the
`PingAck` reply so the agent advertises the capability as `degraded`
rather than `enabled`.

#### Scenario: BPF load failure surfaces as degraded capability
- **WHEN** the sidecar fails to load any eBPF program at start
- **THEN** the sidecar logs the failure, sets its internal mode to
  degraded
- **AND** subsequent `PingAck` replies indicate
  `flow_attribution_available = false`
- **AND** the agent advertises `host-network-visibility = degraded`

### Requirement: Process snapshot stream

`serviceradar-netprobe` SHALL emit periodic `ProcessSnapshot` events
listing the host's listening sockets and their owning processes at the
cadence specified by `process_snapshot_interval_s`. A zero value
disables the stream. Each snapshot MUST include a stable fingerprint so
the agent can suppress unchanged snapshots downstream.

#### Scenario: Unchanged snapshot is fingerprint-equivalent
- **WHEN** two consecutive snapshots reflect the same listening sockets
  and PIDs
- **THEN** their snapshot fingerprints are identical
- **AND** the agent suppresses re-publication downstream while
  preserving the freshness timestamp on the agent host's device record

### Requirement: External NetFlow attribution join

`serviceradar-netprobe` SHALL accept `ExternalFlowRecord` messages
forwarded by the agent and annotate them with local process attribution
when their 5-tuple matches an observed local socket lifecycle entry
within a configurable matching window. Annotated records MUST be
emitted as `FlowAttributionEvent` records with `source =
"external_netflow"`. Unmatched records MUST be dropped silently and
counted.

#### Scenario: External NetFlow record matches a local socket
- **WHEN** the agent forwards a NetFlow record whose 5-tuple matches an
  active local TCP connection owned by `nginx` PID 1234
- **THEN** the sidecar emits a `FlowAttributionEvent` with
  `source = "external_netflow"`, `pid = 1234`, and `comm = "nginx"`

#### Scenario: Unmatched external record is dropped and counted
- **WHEN** the agent forwards a NetFlow record whose 5-tuple does not
  match any local socket within the matching window
- **THEN** the sidecar does not emit a `FlowAttributionEvent` for it
- **AND** increments
  `serviceradar_netprobe_external_flow_unmatched_total`

### Requirement: Sample-interval rate limiting

For each (device IP, signal-class) pair the sidecar SHALL honour the
`sample_interval_ms` value supplied in the device binding, emitting at
most one event per interval per class. A zero or absent value disables
rate limiting for that pair.

#### Scenario: Repeated TCP fingerprints within the window are coalesced
- **WHEN** a device binding sets `sample_interval_ms = 60000` and the
  sidecar observes ten TCP handshakes for the device IP within 60
  seconds
- **THEN** the sidecar emits exactly one TCP `FingerprintEvent` for that
  device IP in the window

### Requirement: Privacy redaction at the IPC boundary

The sidecar SHALL NOT emit packet payloads, full HTTP URIs, HTTP
request or response bodies, DNS query names by default, full process
command lines by default, or any process environment variable across
the IPC boundary. Opt-in capture of full HTTP URIs, DNS query names, or
full command lines MUST require an explicit flag in the device binding
and MUST be reflected in the audit trail of the controlling
`VisibilityProfile`.

#### Scenario: Default DNS event omits the query name
- **WHEN** the sidecar dissects a DNS query
- **THEN** the emitted `DpiEvent.dns` payload carries the record type
  and RCODE
- **AND** does not carry the query name

#### Scenario: Command line redacted by default
- **WHEN** a process with command line
  `/usr/sbin/nginx -c /etc/nginx/nginx.conf -g daemon off;` is
  attributed
- **THEN** the emitted `FlowAttributionEvent.cmdline` contains
  `/usr/sbin/nginx <args-hash>`
- **AND** does not contain the literal arguments

### Requirement: IPC protocol

The Go agent and `serviceradar-netprobe` SHALL communicate over a Unix
domain socket using length-prefixed protobuf framing. The protocol MUST
expose at least `ApplyConfig(VisibilityAgentConfig)`,
`Ping()/PingAck()`, four server-streamed event channels
(`FingerprintEvents`, `DpiEvents`, `FlowAttributionEvents`,
`ProcessSnapshots`), and one client-streamed channel
(`IngestExternalFlows`) as defined in
`proto/agent/netprobe/v1/netprobe.proto`. Each frame MUST be prefixed
with a 4-byte big-endian length and MUST NOT exceed 4 MiB. The schema
MUST be additive only within the v1 package.

#### Scenario: Oversized frame is rejected
- **WHEN** either party receives a frame whose declared length exceeds
  4 MiB
- **THEN** the receiver closes the UDS connection
- **AND** the agent's sidecar supervisor reconnects under back-off

#### Scenario: Single-connection IPC socket
- **WHEN** a second client attempts to connect while an active agent
  connection exists
- **THEN** the sidecar rejects the second connection without disturbing
  the active session

### Requirement: Unified visibility profile model

ServiceRadar SHALL persist visibility policy as
`Serviceradar.Inventory.VisibilityProfile` Ash resources with
attributes `name` (unique within partition), `description`, `enabled`,
`target_query` (SRQL, default `in:devices` when blank), `priority`,
`fingerprint` map (`tcp`, `tls`, `http`), `dpi` map (`enabled`,
`protocols` list), `flow_attribution` map (`tcp`, `udp`, `quic`),
`process_snapshot_interval_s`, `sample_interval_ms`, `retention_days`,
partition identifier, and standard temporal fields. Profiles MUST be
tenant-scoped and authorised via `Ash.Policy.Authorizer`.

#### Scenario: Blank target query resolves to default scope
- **WHEN** an operator creates a profile with `target_query` left empty
- **THEN** the profile is treated as scoping all devices in the
  partition (equivalent to `in:devices`)

#### Scenario: Higher priority profile wins on overlap
- **WHEN** two enabled profiles match the same device
- **THEN** the per-device compiled binding reflects the profile with
  the higher `priority`

### Requirement: Capture-interface allowlist binds remote capture sessions

`serviceradar-netprobe` SHALL refuse any remote packet capture
session (per `remote-packet-capture`) whose `target_interfaces` are
not a subset of the allowlist supplied in
`VisibilityAgentConfig.capture_interfaces`, regardless of whether
the requesting user holds `agent_capture:remote`. The same
deny-by-default allowlist that gates passive observation MUST gate
remote capture.

#### Scenario: Capture session for non-allowlisted interface is rejected
- **WHEN** a remote capture request targets interface `eth2` and the
  allowlist contains only `eth0` and `eth1`
- **THEN** `netprobe` refuses the session and emits a structured
  error to the agent

### Requirement: Per-device binding compilation

A `VisibilityCompiler` SHALL compile per-device bindings by evaluating
each enabled `VisibilityProfile.target_query` via the shared
`SrqlTargetResolver`. The resolved per-device map MUST be emitted
inside `AgentConfigResponse.visibility_config` alongside the existing
`sysmon_config` and `snmp_config` fields.

#### Scenario: Device with no matching profile receives no binding
- **WHEN** a device matches no enabled profile's `target_query`
- **THEN** the compiled `visibility_config.device_bindings` omits that
  device
- **AND** the sidecar performs no per-device analysis for the device IP

#### Scenario: Imported device receives a binding when profile scope matches
- **WHEN** a device sourced from Armis, NetBox, or UniFi sync matches an
  enabled profile's `target_query`
- **THEN** the compiled `visibility_config.device_bindings` includes a
  binding for the device's canonical IP
