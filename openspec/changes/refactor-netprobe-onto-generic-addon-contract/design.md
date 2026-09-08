# Design

## Context

netprobe is a native add-on by delivery (signed, versioned, Edge-Ops targeted) but not by runtime
contract. Its data plane is a bespoke 12-arm `oneof` over a length-framed Unix socket, and each arm
is hand-plumbed through the agent. The cost is not the transport — it is that the agent must
understand every payload, so a new payload type is a cross-component change ending in an agent
release.

Two constraints shape every decision below.

**netprobe must stay root-started and externally supervised.** See the proposal for the four
measured blockers: the agent's `CapabilityBoundingSet` has no `CAP_BPF`, running as the
`serviceradar` uid was tried and reverted with a regression test guarding it, the privileged
pre-start steps have no hook in go-plugin's launch path, and go-plugin's `SIGKILL`-only shutdown
would leak TC/XDP attachments on every agent restart.

**The identity guardrails must not be able to drift.** `SourcePolicy.passive_census_source?/1` and
`enrichment_only_source?/1` decide whether a MAC may anchor a device and whether a source may create
one. They key on the update's `source` string **or** its `metadata["identity_source"]`
(`source_policy.ex:53-56, 84-88`), and `census_translator.go:44-46` sets both deliberately: *"Both
are set so the guardrail still recognises the update if a downstream hop rewrites `source`."*
`include_mac_identifier?` → `census_anchorable_mac?` additionally reads `metadata["mac"]`, so the
MAC must stay inside the metadata map and not only as a top-level field.

That pairing **is** enforced today, contrary to a first reading of `results_router.ex:225-251`:
`source_policy_census_test.exs:150-181` iterates `ResultsRouter.census_service_types/0` and asserts
`SourcePolicy.passive_census_source?/1` for each, and `source_policy_mdns_test.exs:73-105` does the
same for `enrichment_only_source?/1` plus a disjointness check. The hazard this change introduces is
different and worse: the new path does not go through `ResultsRouter` at all, so those tests would
keep passing while guarding a route nothing uses.

## Goals / Non-Goals

**Goals**
- Adding a payload type to netprobe requires **zero** agent, gateway or proto changes.
- netprobe speaks the same `AddonService` contract as every other native add-on.
- Device identity construction moves next to the policy that governs it.
- The router/policy invariant extends to the new route rather than being orphaned by it.

**Non-Goals**
- Changing netprobe's privileges, supervision, socket ownership or process lifetime.
- Widening the agent's `CapabilityBoundingSet`.
- A generic `attach` transport in the add-on manager (see "Rejected alternatives").
- Touching the Helm/Kubernetes netprobe path (no template renders it; `agent.netprobe.enabled` is
  inert).
- Migrating dead IPC arms. They are deleted.

## Decisions

### One payload kind, schema strings underneath

```proto
// proto/agent/addon/v1/addon.proto
TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1 = 8;
```

```proto
// proto/agent/discovery/v1/discovery.proto
message DiscoveryEnvelope {
  string schema                 = 1;  // "serviceradar.netprobe.census.v1"
  string producer_id            = 2;  // add-on id; informational, never trusted for identity
  string observation_scope      = 3;  // supersession key (e.g. interface); "" = none
  string snapshot_id            = 4;  // set => snapshot semantics; "" => event semantics
  uint32 part_index             = 5;
  uint32 part_count             = 6;
  bool   complete               = 7;
  int64  generated_at_unix_nano = 8;
  uint64 dropped_since_last     = 9;
  bytes  payload                = 10; // schema-specific; decoded only in core
}
```

**Why not one kind per payload.** A kind per payload rebuilds the closed enum one level up: every
new type would touch the proto, Go codegen, Elixir codegen, the Rust SDK, the gateway and core.
With a schema string, adding "netprobe LLDP snapshots" is netprobe emitting
`schema: "serviceradar.netprobe.lldp.v1"` and core registering one entry. Agent, gateway and proto
untouched — that property is the entire point of the change.

**Why not `TelemetryRecord.metadata`.** It is a closed 9-key allowlist in core
(`status_handler.ex:51-61`) whose `payload_kind` field accepts only `ocsf_event` / `otel_log`.

**Why not `PluginResultIngestor` / `source: "plugin-result"`.** That is the wasm runtime's contract
with its own lifecycle. Coupling native add-ons to it entangles two unrelated systems.

### The agent side is a pump, not a transport abstraction

netprobe binds a second socket post-`--drop-user` and serves `AddonService`. The agent holds an
`addonpb.AddonServiceClient` for it and pumps `StreamTelemetry` batches into the **existing**
`Server.handleAddonTelemetry(addonID, batch)` buffer — the same buffer
`bumblebee_spool_service.go:114-152` reaches through `StatusAddonTelemetryProvider`
(`interfaces.go:57-61`), an interface whose doc comment already says it exists *"for native
systemd-timer add-ons"*. From that buffer onward, `push_loop_addon_telemetry.go:128-149` marshals
the batch opaquely and never reads `payload_kind`.

This lives beside the existing `netprobe.AttachManager`, which already owns socket discovery,
readiness and health. What remains netprobe-specific in the agent after the cutover is socket
discovery plus a payload-agnostic pump — no translators, no push loops, no chunk assemblers, and
nothing that changes when a payload type is added.

### Per-payload semantics move out of the agent

| Today (agent) | After |
|---|---|
| chunk reassembly (`chunk_assembler.go`, 240 lines + 2 wrappers) | core. The 4 MiB cap is a `NetprobeFrame` artifact; `part_index`/`part_count` carry the >6 MiB case |
| newest-per-interface collapse (`sidecar.go`) | netprobe: it is the producer and knows which snapshot is current. `observation_scope` + `generated_at_unix_nano` let core apply the rule defensively |
| device-update translation (3 translators, ~430 lines) | core, next to `SourcePolicy` |
| skip rules (no-MAC, `off_segment`, no-evidence, ambiguous-model, banner confidence floor) | core — these are identity-safety rules |
| suppression / rate limiting | unchanged, already in netprobe |
| flow-attribution ack + terminal poison handling | unchanged: stays agent-owned on its dedicated ordered-prefix `StreamStatus` path, never the generic telemetry relay; invalid bytes are dropped with telemetry rather than copied into a quarantine store |

**Chunk reassembly is not deferrable.** `push_loop_addon_telemetry.go:71-78` `continue`s past a
batch over 6 MiB — the *entire* census is dropped with a Warn and no re-queue. The failure mode is
total stream silence on exactly the largest segments, which is where the census matters most. Core
must implement `part_index` reassembly in the same PR as the decoders, not as a later fallback.

### Core ingest path

1. `StatusHandler.publish_package_telemetry_record/3` gains one branch: a `DISCOVERY_V1` record goes
   to `DiscoveryIngestor`.
2. `DiscoveryIngestor` looks up `schema` in `DiscoverySchemaRegistry`. **An unknown schema is a loud
   drop** — rate-limited `Logger.warning` plus `:telemetry.execute`, mirroring
   `drop_misbucketed_metric/2`. Never a silent `true -> :ok`; that catch-all is exactly how a stream
   reports HEALTHY while discarding everything.
3. The decoder produces **observations only** — `ip`, `mac`, timestamps, payload metadata. Decoders
   must not read identity from the payload, and must keep `metadata["mac"]` populated because
   `census_anchorable_mac?/1` reads it.
4. `DiscoveryIngestor` stamps `agent_id`, `gateway_id` and `partition` from the **gateway-attested**
   status metadata, and `source` **and** `metadata["identity_source"]` from the registry. An
   add-on-supplied `agent_id` or `source` can never reach `SyncIngestor`. `addon.proto:229-231`
   already states `TelemetrySource.metadata` is untrusted.
5. Snapshot buffering by `snapshot_id` (5-minute TTL, bounded set count — the same rules
   `chunk_assembler.go` enforces, relocated), then newest-per-`observation_scope`.
6. `SyncIngestorQueue.enqueue/1` with a JSON-encoded list, landing in `SyncIngestor.ingest_updates/2`
   behind `SourcePolicy` exactly as today.

### The registry entry declares both recognition channels

```elixir
"serviceradar.netprobe.census.v1" => %{
  source:          "netprobe-census",
  identity_source: "netprobe_census",
  policy_class:    :passive_census,
  decoder:         Decoders.Census
}
```

The consistency test asserts, for every registered schema, that `SourcePolicy` reaches the declared
`policy_class` via **each** channel independently — once with only `source` set, once with only
`metadata["identity_source"]` set. A schema whose source `SourcePolicy` does not classify fails the
build. This is an extension of the existing `census_service_types/0` / `mdns_service_types/0`
invariant, not a replacement: while both routes are live, both are asserted.

### Gateway prerequisite

`proto/agent/addon/v1/addon.proto` has **no Elixir codegen**: it is absent from the
`make generate-proto-elixir` list and covered by no `elixir_proto_library`, so
`make verify-proto-elixir` reports clean regardless. Adding enum value 8 today would mean
hand-editing a generated file with no drift detection. That is fixed first.

**Partition stamping is scoped narrowly.** Inventory writes must be stamped from the authenticated
mTLS view, but `@strict_delivery_sources` does more than that: a strict-delivery status **bypasses
the lenient rescue** (`agent_gateway_server.ex:507, 1647`), so any exception in any `addon:` status
aborts the whole chunk. Adding an `addon:` prefix there would change failure semantics for
otel-collector, powerdns, anomaly-addon and bumblebee. The change is therefore made in
`status_partition/3` only — force the mTLS partition for `addon:` sources — and
`strict_delivery_service?` is left alone.

## Rejected alternatives

**A generic `attach` transport in the add-on manager.** Superficially the "right" shape: give
`AddonAssignmentConfig` a `plugin_transport ∈ {exec, attach}` and let the manager dial a socket.
Rejected for now because `push_loop_addons.go:401-446` switches on `classifyAddonSupervision`, and
`systemd-service` routes to `addonDispatchSystemd`, which never builds a `Spec` and so never reaches
`manager.Apply`. Making netprobe both systemd-delivered and manager-run needs a new dual-dispatch
state plus changes to `needsRestart` (which compares `BinaryPath`/`Args`/`Version`, meaningless for
attach), the `defer client.Kill()` path, and the delivered-spec version reporting — and it lands on
`addon_rollout_eligibility.ex`, where `tolerated_failures: 0` means one target that cannot report
health fails the rollout for the whole fleet. That is a worthwhile change; it belongs in its own
proposal, proven against the rust-sample add-on, not bolted onto netprobe's cutover.

**Agent-launched netprobe via go-plugin.** See the proposal. Four measured blockers, and clearing
them requires widening the agent's capability bounding set — the exact boundary the units and docs
exist to hold.

## Risks / Trade-offs

1. **Dual-emit would double-write inventory.** During the cutover both the `results`/`netprobe-census`
   route and the `addon:`/`DISCOVERY_V1` route can be live on one host, and core would ingest each
   census twice. The suppression rule is explicit: the agent stops draining the legacy snapshot
   channel the moment the `AddonService` client connects, and falls back if it disconnects. Emitting
   on both sockets is netprobe's job; consuming from exactly one is the agent's.
2. **Mixed-version fleet.** The agent ships as a package; netprobe as a pushed artifact on a
   different cadence. The agent must tolerate a netprobe with no `addon.sock`, and netprobe must
   tolerate an agent that never connects to it. Never a flag day.
3. **`FlowAttributionEventBatch`'s Elixir decoder is hand-mirrored** (`flow_attribution_event.pb.ex`
   declares fields by hand with a comment demanding manual sync against `.proto` line numbers). Any
   reshape breaks core decoding with no build failure. Keep those bytes byte-identical and add real
   generation in the same PR.
4. **Health/capability data has no generic carrier yet.** `PingAck` carries `running_as_root` and
   four corpus revisions that `push_loop_capabilities.go:224-270` turns into the banner-grab
   capability status. They must land on `AddonService.Health` before the IPC is deleted, or capability
   reporting silently goes dark.
5. **Config delivery is a third channel that must be designed, not assumed.** netprobe has a
   bootstrap file (where `enabled:false` is terminal until restart), the `ApplyConfig` IPC arm, and a
   config-hash-driven restart for the two fields that hard-bail (`capture_interfaces`,
   `flow_table_max_entries`). `AddonService.Configure` replaces the IPC arm; the file and the
   restart-only fields need explicit treatment, and `addon_config_contract_fixtures.ex:61-72` /
   `addon_config_contract_test.go` pin the contract cross-language.
6. **Static-link regression on netprobe** from `rustls`/`ring`/`rcgen`.
   `//rust/netprobe:static_linkage_test` asserts no `PT_INTERP` and no `DT_NEEDED` on both x86_64 and
   aarch64 musl. Measure before committing to the stack.
7. **Rollout eligibility.** `netprobe_addon_package_seeder.ex` reads `addon.yaml` at compile time and
   hardcodes `supervision: :systemd_service`; the mandatory version bump mints a new `AddonPackage`
   and a rollout. Confirm what an `AddonService`-serving netprobe reports as state/active and that
   `supervision_state_ready?` accepts it, before the first netprobe release in this stack.
8. **Loss semantics.** `StreamTelemetry` is lossy. Census supersedes every 120 s and mDNS every
   300 s, so a dropped snapshot self-heals. Flow attribution does not, so it remains on the existing
   agent-owned ordered-prefix/`StreamStatus` path. Convenience must not move it to `StreamTelemetry`
   or `RelayOtlp`; `harden-flow-attribution-pipeline` owns truthful negative acknowledgement and
   bounded core admission for that path.
9. **Pre-existing TC/XDP leak.** `attach_tc_programs` / `attach_xdp_program` never detach stale
   programs (only `start_census_only` does). Unrelated to this change but worth fixing first.

## Migration Plan

Behavior-preserving groundwork first (nothing deployed changes), then per-payload cutovers with the
single-consumer rule above, then deletion. Flow attribution's local producer transport goes last: it
is the only payload with a real delivery contract, the only one hand-decoded in Elixir, and the only
one where a drop does not self-heal. Its agent-to-platform ordered-prefix/`StreamStatus` contract is
preserved rather than replaced by a generic relay.

Golden fixtures are captured from the current Go translators **before** anything is deleted; they
are the only evidence that the move is behavior-preserving.

## Open Questions

- Does a real census snapshot on the largest fleet segment fit in one 6 MiB `TelemetryBatch`?
  Measured in task 1.6. It does not change whether reassembly is built — it is built either way —
  only whether the path is exercised in normal operation.
- Should `DiscoverySchemaRegistry` remain compile-time, or become operator-extensible later? Starting
  compile-time: an operator-registerable identity source is a much larger security question.
