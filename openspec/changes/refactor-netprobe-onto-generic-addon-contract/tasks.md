## 1. Groundwork (nothing deployed changes)

- [ ] 1.1 Generate the Elixir binding for `proto/agent/addon/v1/addon.proto`: add it to the
  `make generate-proto-elixir` list and an `elixir_proto_library`, commit the generated file, and
  confirm `make verify-proto-elixir` now actually covers it (it reports clean today because the
  file is absent from the list entirely)
- [ ] 1.2 Replace the silent `true -> :ok` fallthrough for unhandled add-on telemetry payload kinds
  in `status_handler.ex` with a rate-limited `Logger.warning` + `:telemetry.execute`, mirroring
  `drop_misbucketed_metric/2`; test asserts the telemetry event fires for an unknown kind
- [ ] 1.3 Force the mTLS-attested partition for `addon:` sources in `status_partition/3` **only**;
  do NOT add `addon:` to `@strict_delivery_sources` (that would change failure semantics from
  swallow to re-raise for otel-collector, powerdns, anomaly-addon and bumblebee). Test: an `addon:`
  status with a mismatched `service.partition` is stored under the certificate's partition
- [ ] 1.4 Add `TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1 = 8` to `proto/agent/addon/v1/addon.proto` and a
  new `proto/agent/discovery/v1/discovery.proto` carrying `DiscoveryEnvelope`; regenerate Go,
  Elixir and Rust, mirror into `rust/addon-sdk/proto/`, add `BUILD.bazel`. No consumers yet
- [ ] 1.5 Capture golden fixtures from the CURRENT Go translators: for a set of real census, mDNS,
  DPI, fingerprint and process snapshots, record the exact update-map JSON
  `census_translator.go`, `mdns_translator.go` and `translator.go` produce. These are the only
  evidence the move is behavior-preserving — capture before deleting anything
- [ ] 1.6 Measure a real census and mDNS snapshot on the largest segment in the fleet against the
  6 MiB `TelemetryBatch` cap, and record the number in this change. Reassembly is built either way
  (task 2.3); this decides whether the path is exercised in normal operation
- [ ] 1.7 Fix the pre-existing stale TC/XDP attachment leak: `attach_tc_programs` and
  `attach_xdp_program` never detach a prior program (only `start_census_only` does, and its comment
  records a host with three stacked classifiers after three restarts)

## 2. Core: the generic discovery ingest path

- [ ] 2.1 Add `ServiceRadar.Inventory.DiscoverySchemaRegistry` mapping schema →
  `%{source, identity_source, policy_class, decoder}`. Compile-time table; no operator extension
- [ ] 2.2 Add the consistency test. For every registered schema, assert `SourcePolicy` reaches the
  declared `policy_class` via **each** recognition channel independently — once with only `source`
  set, once with only `metadata["identity_source"]` set (`source_policy.ex:53-56, 84-88`). A schema
  whose source `SourcePolicy` does not classify MUST fail the build. This EXTENDS the existing
  invariant in `source_policy_census_test.exs:150-181` and `source_policy_mdns_test.exs:73-105`;
  while both routes are live, both are asserted
- [ ] 2.3 Add `DiscoveryIngestor`: schema lookup, loud drop on unknown schema, snapshot buffering by
  `snapshot_id` (5-minute TTL, bounded set count), `part_index`/`part_count` reassembly,
  newest-per-`observation_scope`, then `SyncIngestorQueue.enqueue/1`. Reassembly is NOT optional —
  `push_loop_addon_telemetry.go:71-78` drops an over-cap batch entirely with no re-queue
- [ ] 2.4 Add decoders for census, mDNS, DPI and fingerprint, porting the skip rules from the Go
  translators verbatim (no-MAC, `off_segment`, no-evidence, ambiguous-model suppression). Decoders
  emit observations only and MUST keep `metadata["mac"]` populated — `census_anchorable_mac?/1`
  reads it
- [ ] 2.5 `DiscoveryIngestor` stamps `agent_id`/`gateway_id`/`partition` from gateway-attested status
  metadata and `source`/`identity_source` from the registry; an add-on-supplied `agent_id` or
  `source` MUST NOT reach `SyncIngestor`. Test the hostile case explicitly
- [ ] 2.6 Wire the `DISCOVERY_V1` branch into `StatusHandler.publish_package_telemetry_record/3`
- [ ] 2.7 Golden-fixture tests: the Elixir decoders produce byte-identical update maps to the 1.5
  fixtures

## 3. netprobe serves AddonService

- [ ] 3.1 Add `addon-sdk` to `rust/netprobe`; bind a second socket post-`--drop-user` and serve
  `AddonService` via `serve_on_listener(addon, listener, None)`. Implement `Info` / `Configure` /
  `Health`. Legacy `NetprobeFrame` socket untouched
- [ ] 3.2 Enforce peer identity on the new socket with `SO_PEERCRED` plus socket mode. The current
  IPC socket has no peer check at all; `AddonService` exposes `Configure` and `RunCommand`, so this
  ships in the same PR that binds the socket
- [ ] 3.3 Carry `running_as_root` and the p0f/muonfp/recog/satori corpus revisions from `PingAck`
  onto `AddonService.Health`, and repoint `push_loop_capabilities.go:224-270` at it. Without this,
  deleting the IPC silently turns banner-grab capability reporting off
- [ ] 3.4 Emit census and mDNS as `DISCOVERY_V1` over `StreamTelemetry`; collapse
  newest-per-interface in netprobe rather than the agent
- [ ] 3.5 Verify `//rust/netprobe:static_linkage_test` still passes on x86_64 AND aarch64 musl with
  the new dependency closure (`rustls`/`ring`/`rcgen`); no `PT_INTERP`, no `DT_NEEDED`
- [ ] 3.6 Bump `addons/netprobe/addon.yaml` version and `NETPROBE_VERSION`; register
  `rust/addon-sdk/*` under netprobe's `path_belongs_to_addon` in
  `scripts/check-native-addon-version-bumps.sh` (powerdns has the same gap — fix both); run
  `bazel test //build/native_addons:build_gates_test`
- [ ] 3.7 Confirm what an `AddonService`-serving netprobe reports as state/active and that
  `addon_rollout_eligibility.ex` `supervision_state_ready?` accepts it — `tolerated_failures: 0`
  means one target that cannot report health fails the rollout for the whole fleet

## 4. Config path

- [ ] 4.1 Specify and implement the config path before its transport is deleted: `AddonService.Configure`
  replaces the `ApplyConfig` IPC arm; define what still writes the bootstrap file (where
  `enabled:false` is terminal until restart) and how the two restart-only fields
  (`capture_interfaces`, `flow_table_max_entries`) are handled
- [ ] 4.2 Update the cross-language config contract fixtures that pin this:
  `elixir/.../plugins/addon_config_contract_fixtures.ex:61-72` and
  `go/pkg/agent/addon_config_contract_test.go`

## 5. Agent cutover

- [x] 5.1 Pump netprobe's `StreamTelemetry` batches into the existing
  `Server.handleAddonTelemetry(addonID, batch)` buffer, beside the existing `netprobe.AttachManager`
  which already owns socket discovery and health. Do NOT add a transport abstraction, `Spec.Transport`,
  a manifest-schema field, or an add-on-manager dispatch arm — see design.md "Rejected alternatives"
- [x] 5.2 Single-consumer rule: the agent stops draining the legacy census/mDNS snapshot channel the
  moment the `AddonService` client connects, and falls back if it disconnects. Without this, core
  ingests each census twice during the cutover
- [x] 5.3 Delete `push_loop_netprobe_census.go`, `push_loop_netprobe_mdns.go`,
  `netprobe/census_translator.go`, `netprobe/mdns_translator.go`, `netprobe/census_assembler.go`,
  `netprobe/mdns_assembler.go`, `netprobe/chunk_assembler.go`, `DrainCensusSnapshots`,
  `DrainMdnsSnapshots`, and the tag-30/31 readLoop arms
- [ ] 5.4 Move DPI, fingerprint and process snapshots onto `DISCOVERY_V1`; delete
  `netprobe/translator.go` and the netprobe half of `push_loop_mapper_netprobe.go`. Process snapshots
  gain real snapshot semantics, fixing today's partial-fragment device updates (netprobe splits them
  across frames with no chunk fields)
- [ ] 5.5 Move banner matching to `AddonService.RunCommand`; the confidence and unknown-corpus filters
  move into netprobe.

  **DESIGNED AND NOT BUILT -- as written this does not achieve its purpose.**
  Verified 2026-08-24:

  * **The filters are nearly a no-op.** `rust/netprobe/src/ipc/match_banner.rs`
    returns exactly ONE `BannerMatch` per observation, in order, using an
    `unknown_match` sentinel (`corpus_label: "unknown"`, `confidence: 0.0`) for a
    miss -- padding that exists only to keep the response positionally 1:1. The
    agent's two filters (`banner_grab_handler.go:160`) delete exactly that
    padding: there is no match with `confidence <= 0` and a non-"unknown" label,
    nor "unknown" with `confidence > 0`. "Move the filters into netprobe" means
    "stop emitting the padding".
  * **It does not unblock the 5.4 deletion.** Read literally (RunCommand returns
    matches) the agent still runs `bannerMatchToFingerprintEvent` ->
    `EnqueueFingerprintEvent` -> `s.events` -> `DrainEvents` -> `translator.go`.
    Only the wire changes.
  * **Do NOT collapse active fingerprints into `serviceradar.netprobe.fingerprint.v1`.**
    The ingestor stamps the top-level source from the registry, so they would
    arrive as `passive-netprobe` and a device's `discovery_sources` would stop
    saying `sweep_active`. An active banner grab is the strongest present-tense
    evidence of address occupancy netprobe produces -- a completed TCP handshake
    plus an application banner, unspoofable off-path -- and should not be filed
    under the passive source. If they ever move, register a SECOND schema whose
    registry entry carries `source: "sweep_active"`.
  * **Two prerequisites do not exist.** netprobe cannot construct a
    `FingerprintEvent` (the agent supplies host/timestamp/protocol from its own
    `BannerObservation`), and the agent has NO RunCommand client for netprobe --
    `AttachManager` builds only the StreamTelemetry pump.
  * **Rollout:** the add-on ships independently (`delivery: pushed-artifact`,
    `base_agent: ">=1.2.0"`, a floor), so the agent must try RunCommand and FALL
    BACK to the IPC `MatchBanners`; the IPC call may only be deleted a release
    later, once the netprobe version implementing it has converged.

  **Checked and NOT a problem** (recorded so it is not re-raised): a review
  claimed a stale alias would capture these observations. It does not.
  `Lookups.lookup_alias_device_ids_by_ip` filters `state in [:confirmed, :updated]`,
  and every `find_device_uid_by_alias` caller in `mapper_results_ingestor.ex`
  resolves by primary IP FIRST (`find_live_device_uid_by_ip:586`,
  `resolve_or_create_topology_candidate_uid:729`, `do_ensure_candidate_device:1376`,
  `resolve_device_ids:1455` before `create_missing_devices:1458`). The alias path
  is reached only when no device owns the address directly. The narrow residual
  case is an address whose own device is absent or soft-deleted, where a `:stale`
  alias can both mis-attribute and be reactivated (`maybe_reactivate_alias:1736`).

- [ ] 5.6 Move flow attribution to a generalized acked relay: generalize `RelayOtlp`'s hardcoded
  identity constants and the gateway's `otlp_relay_publisher.ex` routing. Keep
  `FlowAttributionEventBatch` payload bytes byte-identical so the hand-mirrored
  `flow_attribution_event.pb.ex` decoder keeps working, and add real generation for that file in the
  same change. Keep the ack/quarantine queue at the agent
- [ ] 5.7 Delete the dead arms rather than porting them: `ExternalFlowRecord`/`ExternalFlowAck`
  (test-only callers), `StartRemoteCapture`/`PcapngBlock` (empty messages, no code), and the tag-21
  non-batched flow-attribution fallback (disabled by default)

## 6. Retire the bespoke IPC

- [ ] 6.1 Delete `go/pkg/agent/netprobe/` and the netprobe `oneof` arms; netprobe stops binding the
  legacy socket. Land only after 5.1-5.7 are confirmed in the fleet
- [ ] 6.2 Retire the `@census_service_types` / `@mdns_service_types` `ResultsRouter` clauses and
  redirect their tests at the registry invariant, so no test is left guarding a route nothing uses.

  **BLOCKED, and the clauses are NOT "now-dead" — verified 2026-08-23.** The census producer
  shipped in **v1.4.42**, the current `VERSION`: `git cat-file -e v1.4.42:go/pkg/agent/push_loop_netprobe_census.go`
  resolves, and `v1.4.42:go/pkg/agent/push_loop.go:554` calls it unconditionally every push cycle,
  emitting `service_type: "netprobe-census"` with the hardcoded `source: "results"`
  (`push_loop_status.go:670-679`) -- a byte-exact match for the guard at `results_router.ex:284`.
  Nothing between agent and router filters it. Agents roll independently of core, so
  "new core + old agent" is the normal intermediate state of every rollout; the 5.3 deletion's
  safety argument covers agent<->netprobe co-location on one host, NOT agent<->core skew, which is
  the axis this task depends on. (The mDNS half genuinely never reached a tag -- absent from
  v1.4.42 -- but splitting the two leaves the task neither done nor undone.)

  **And when it unblocks, this must NOT be a bare deletion.** With the clauses gone the status falls
  through to `results_router.ex:363` `defp process(_status, _opts), do: :ok`, which is total: no
  crash, no log line, and `:ok` lets `publish_status_update/1` upsert the service **HEALTHY** while
  discarding 100% of the payload. The census stream is snapshot-superseding, so each dropped push is
  gone with no backfill -- device inventory, not recoverable telemetry. A crash would be strictly
  safer than this. Replace the two clauses with ONE explicit retirement clause that logs at
  `warning` (sampled -- an old agent emits every cycle) naming the service type and the emitting
  `agent_id`, plus a countable telemetry event, mirroring `discovery_ingestor.ex:76-94`
  (`outcome: :unregistered_schema`). Delete THAT clause a release or two later, once the warning has
  stayed silent. Keep one test asserting the drop is loud rather than deleting
  `results_router_test.exs:197-236` outright.

## 7. Verification

- [x] 7.1 Go unit tests: the pump forwards an opaque batch without inspecting it; the single-consumer
  switchover; fallback when `addon.sock` is absent
- [ ] 7.2 Elixir DB-backed tests (srql-fixtures lifecycle): census updates satisfy
  `passive_census_source?/1`, mDNS updates satisfy `enrichment_only_source?/1` and create no device,
  a hostile `source`/`agent_id` in the payload is ignored, an unknown schema is dropped loudly
- [ ] 7.3 e2e on `alma-test01`: netprobe emits `DISCOVERY_V1` → agent forwards → core ingests →
  devices appear with the same identity they had before the cutover (compare against the 1.5 fixtures)
- [ ] 7.4 Add a NEW payload schema end-to-end and confirm it required **zero** agent, gateway and
  proto changes. This is the acceptance test for the whole change
- [ ] 7.5 `openspec validate refactor-netprobe-onto-generic-addon-contract --strict`
