# Change: Move netprobe onto the generic add-on contract so payloads never touch the agent

## Why

An add-on is supposed to be decoupled from the agent: the add-on produces, the agent forwards, the
agent knows nothing about the contents. netprobe is not. It speaks a bespoke typed IPC
(`proto/agent/netprobe/v1`, a 12-arm `oneof` on tags 20-31) and every arm requires agent-side code:
12 readLoop arms, 6 sidecar drain methods, 3 translators, 4 push loops and 2 chunk assemblers —
roughly 4,900 lines of netprobe-specific non-test Go in the agent. Adding one payload type to
netprobe means editing the agent, regenerating protos, and shipping a new agent package. That is
the opposite of what an add-on is for.

The generic path already exists and is already payload-agnostic. `push_loop_addon_telemetry.go`
marshals a whole `TelemetryBatch` opaquely and never reads `payload_kind`, and
`StatusAddonTelemetryProvider` (`go/pkg/agent/interfaces.go:57-61`) already exists so that a
**systemd-supervised** add-on can put a batch into that buffer. What is missing is a payload kind
that can carry a device observation to the inventory pipeline, and a decoder for it in core.

**netprobe cannot become an agent-launched (`exec`/go-plugin) add-on.** This was investigated and
the blockers are measured, not theoretical:

- `serviceradar-agent.service` sets
  `CapabilityBoundingSet=CAP_NET_RAW CAP_SETFCAP CAP_DAC_OVERRIDE CAP_FOWNER CAP_CHOWN CAP_MAC_ADMIN`
  — no `CAP_BPF`, `CAP_PERFMON` or `CAP_NET_ADMIN`. A file's permitted set is masked by the process
  bounding set, so `setcap` on the staged binary buys nothing. Verified on a live host
  (`alma-test01`, 2026-08-23): netprobe holds those capabilities from its unit's
  `AmbientCapabilities` while running as root, and `getcap` on every staged binary is empty — it
  does not use file capabilities at all today.
- Running netprobe as the `serviceradar` uid was already tried and reverted in `8bea8cac0b`.
  `addons/netprobe/serviceradar-netprobe.service:10-12` records why: *"Starting directly as
  `User=serviceradar` lacks enough privilege on common kernels to create all eBPF maps."*
  `go/pkg/agent/netprobe_systemd_unit_test.go:78` fails the build if that is reverted. An
  agent-`exec`'d child is by construction a `serviceradar`-uid process.
- Three privileged pre-start steps have no hook in go-plugin's launch path: `chcon -t bin_t` on the
  staged binary (203/EXEC on SELinux Enforcing hosts), creating the pinned-map directory, and
  removing stale BPF pins.
- go-plugin never sends `SIGTERM` — it closes the RPC, waits, then `SIGKILL`s. netprobe's graceful
  drain is `SIGTERM`-only, and its TC/XDP attach paths have no stale-detach, so agent restarts
  (`Restart=always`) would leak kernel attachments per restart.

Clearing those would mean widening the agent's bounding set to include `CAP_BPF CAP_PERFMON
CAP_NET_ADMIN`, making *every* add-on the agent ever launches eBPF-capable — the exact boundary
`serviceradar-agent.service` and `docs/docs/native-addons.md` were written to hold.

So netprobe keeps its supervision model and privilege model unchanged. What changes is the
**contract it speaks**: the bespoke `oneof` is replaced by the generic `AddonService`, and its
payloads become opaque bytes the agent forwards without understanding.

This supersedes the claim in `migrate-netprobe-to-native-addon`'s proposal that netprobe "speaks
its own IPC and has its own agent-side client, not the add-on gRPC contract" — it will speak the
add-on contract; only its *launch* model stays different.

## What Changes

- **netprobe serves `AddonService`** on a second Unix socket bound after `--drop-user`, via
  `addon_sdk::serve_on_listener` (already `pub`, already takes a pre-bound `UnixListener`,
  `rust/addon-sdk/src/server.rs:105-109`). No go-plugin handshake, no magic cookie, no AutoMTLS —
  the agent dials it directly. Peer identity is socket mode plus `SO_PEERCRED`, which the current
  `NetprobeFrame` socket has no equivalent of.
- **Add exactly one telemetry payload kind, `TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1`**, carrying a
  self-describing `DiscoveryEnvelope` whose `schema` field is a **string**. Every subsequent payload
  type is a new string registered in core — not a proto edit, not a Go/Elixir/Rust regeneration, and
  not an agent change. A kind-per-payload would rebuild the closed-enum problem one level up.
- **The agent pumps netprobe's batches into the existing generic buffer.** `handleAddonTelemetry`
  and `push_loop_addon_telemetry.go` are already payload-agnostic and are not modified. No new
  transport abstraction, no `Spec.Transport`, no manifest-schema change, no add-on-manager dispatch
  rework — see design.md for why the generic-attach-transport version of this was rejected for now.
- **Extend the existing router/policy pairing test to cover the new route.**
  `source_policy_census_test.exs:150-181` and `source_policy_mdns_test.exs:73-105` already assert
  that every service type `ResultsRouter` accepts is one `SourcePolicy` recognises. The new path
  bypasses `ResultsRouter`, so those tests would keep passing while guarding a dead route. The
  schema registry must be added to the same invariant, and it must cover **both** recognition
  channels: `SourcePolicy` matches on `source` **or** `metadata["identity_source"]`
  (`source_policy.ex:53-56, 84-88`), and `census_translator.go:44-46` sets both on purpose.
- **Move device-update construction out of the agent and into core**, next to `SourcePolicy` and
  DIRE. The census, mDNS and DPI/fingerprint translators, and their skip rules (no-MAC,
  `off_segment`, no-evidence, ambiguous-model suppression, banner confidence floors) are identity
  safety rules; they currently live in a binary that ships on a different cadence than the code
  that owns identity policy.
- **Audit legacy IPC arms before retiring them.** `ExternalFlowRecord`/`ExternalFlowAck` have no Go
  production caller but require config/schema cleanup; `StartRemoteCapture`/`PcapngBlock` remain
  reserved for the approved remote-capture work; and the tag-21 non-batched flow-attribution arm
  remains until published-version skew is bounded and unknown-arm handling is observable. No arm
  is deleted merely because its current-tree caller census is empty.
- **Flow attribution keeps its dedicated agent-owned delivery contract.** The local netprobe source
  may move from `NetprobeFrame` to `AddonService`, but the agent continues sending the byte-identical
  `FlowAttributionEventBatch` through its ordered pending prefix and `StreamStatus`. It does not move
  to lossy `StreamTelemetry` or to `RelayOtlp`; truthful negative acknowledgement and bounded core
  admission are owned by `harden-flow-attribution-pipeline` (#4030/#4031), together with the TCP
  producer and correlation evidence needed to close #4029.
- **Carry netprobe's `PingAck` health fields onto `AddonService.Health`.** `running_as_root` and the
  p0f/muonfp/recog/satori corpus revisions feed `push_loop_capabilities.go:224-270`; deleting the
  IPC without a replacement silently turns banner-grab capability reporting off.
- **Design the config path before deleting its transport.** netprobe has three config channels today
  (bootstrap file, `ApplyConfig` IPC tag 2, and a config-hash-driven restart for the two
  restart-only fields). `AddonService.Configure` replaces the IPC arm; the rest must be specified,
  including the cross-language contract fixtures that pin it.
- **Retire the `NetprobeFrame` IPC** once every payload has moved.

## Impact

- Affected specs: `agent-configuration`, `device-inventory`
- Affected code: `go/pkg/agent/netprobe/` (shrinks to socket discovery + health + a payload-agnostic
  pump, then is deleted), `go/pkg/agent/push_loop_netprobe_*.go`, `proto/agent/addon/v1/`, new
  `proto/agent/discovery/v1/`, `rust/netprobe/`, `elixir/serviceradar_core/lib/serviceradar/inventory/`,
  `elixir/serviceradar_agent_gateway/`
- **Not** affected: netprobe's privileges, supervision, socket ownership or process lifetime. It
  stays root-started under systemd, still `--drop-user`s, and still survives agent restarts. That is
  the primary safety argument for this shape.
- **Not** in scope: a generic `attach` transport in the add-on manager. It is worth doing, but the
  dispatch switch in `push_loop_addons.go:401-446` routes `systemd-service` add-ons away from
  `manager.Apply` entirely, so it is a substantial change of its own and should be proven with the
  rust-sample add-on rather than coupled to netprobe's cutover. Filed separately.
- Relationship to `migrate-netprobe-to-native-addon`: complementary. That change owns delivery,
  signing, targeting and drift; this one owns the runtime contract. Its open tasks 2.1/2.2 are
  unaffected.
