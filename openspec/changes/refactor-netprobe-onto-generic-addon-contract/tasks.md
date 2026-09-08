# Tasks

**Status as of 2026-08-24.** Groups 1-4 are complete and were verified against the code, not
assumed -- the checkboxes had drifted badly enough that this file read as if almost nothing had
been built. Group 5 is most of the way there: census/mDNS cut over, and fingerprint, DPI and
process snapshots now travel `DISCOVERY_V1` with their legacy IPC writers removed.

Four items carry annotations rather than a tick, because "done" would be wrong:

| item | state |
|---|---|
| 3.2 | HALF DONE -- socket mode 0600 landed, `SO_PEERCRED` was never implemented |
| 5.4 | producers and decoders done; the `translator.go` deletion is blocked on 5.5 |
| 5.5 | DESIGNED AND NOT BUILT -- as written it does not achieve its purpose; see the item |
| 6.2 | still blocked; re-checked against `v1.4.42`, not assumed |
| 7.4 | partially demonstrated -- zero agent/gateway changes proven, zero PROTO changes not |

Remaining substantive work, roughly in dependency order: 5.5's prerequisites (netprobe cannot
construct a `FingerprintEvent`; the agent has no `RunCommand` client), then the 5.4 deletion, then
5.6 (flow attribution, the largest untouched piece), 5.7, and group 6 once a release ships without
the legacy producers.

## 1. Groundwork (nothing deployed changes)

- [x] 1.1 Generate the Elixir binding for `proto/agent/addon/v1/addon.proto`: add it to the
  `make generate-proto-elixir` list and an `elixir_proto_library`, commit the generated file, and
  confirm `make verify-proto-elixir` now actually covers it (it reports clean today because the
  file is absent from the list entirely)
- [x] 1.2 Replace the silent `true -> :ok` fallthrough for unhandled add-on telemetry payload kinds
  in `status_handler.ex` with a rate-limited `Logger.warning` + `:telemetry.execute`, mirroring
  `drop_misbucketed_metric/2`; test asserts the telemetry event fires for an unknown kind
- [x] 1.3 Force the mTLS-attested partition for `addon:` sources in `status_partition/3` **only**;
  do NOT add `addon:` to `@strict_delivery_sources` (that would change failure semantics from
  swallow to re-raise for otel-collector, powerdns, anomaly-addon and bumblebee). Test: an `addon:`
  status with a mismatched `service.partition` is stored under the certificate's partition
- [x] 1.4 Add `TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1 = 8` to `proto/agent/addon/v1/addon.proto` and a
  new `proto/agent/discovery/v1/discovery.proto` carrying `DiscoveryEnvelope`; regenerate Go,
  Elixir and Rust, mirror into `rust/addon-sdk/proto/`, add `BUILD.bazel`. No consumers yet
- [x] 1.5 Capture golden fixtures from the CURRENT Go translators: for a set of real census, mDNS,
  DPI, fingerprint and process snapshots, record the exact update-map JSON
  `census_translator.go`, `mdns_translator.go` and `translator.go` produce. These are the only
  evidence the move is behavior-preserving — capture before deleting anything
- [x] 1.6 Measure a real census and mDNS snapshot on the largest segment in the fleet against the
  6 MiB `TelemetryBatch` cap, and record the number in this change. Reassembly is built either way
  (task 2.3); this decides whether the path is exercised in normal operation
- [x] 1.7 Fix the pre-existing stale TC/XDP attachment leak: `attach_tc_programs` and
  `attach_xdp_program` never detach a prior program (only `start_census_only` does, and its comment
  records a host with three stacked classifiers after three restarts)

## 2. Core: the generic discovery ingest path

- [x] 2.1 Add `ServiceRadar.Inventory.DiscoverySchemaRegistry` mapping schema →
  `%{source, identity_source, policy_class, decoder}`. Compile-time table; no operator extension
- [x] 2.2 Add the consistency test. For every registered schema, assert `SourcePolicy` reaches the
  declared `policy_class` via **each** recognition channel independently — once with only `source`
  set, once with only `metadata["identity_source"]` set (`source_policy.ex:53-56, 84-88`). A schema
  whose source `SourcePolicy` does not classify MUST fail the build. This EXTENDS the existing
  invariant in `source_policy_census_test.exs:150-181` and `source_policy_mdns_test.exs:73-105`;
  while both routes are live, both are asserted
- [x] 2.3 Add `DiscoveryIngestor`: schema lookup, loud drop on unknown schema, snapshot buffering by
  `snapshot_id` (5-minute TTL, bounded set count), `part_index`/`part_count` reassembly,
  newest-per-`observation_scope`, then `SyncIngestorQueue.enqueue/1`. Reassembly is NOT optional —
  `push_loop_addon_telemetry.go:71-78` drops an over-cap batch entirely with no re-queue
- [x] 2.4 Add decoders for census, mDNS, DPI and fingerprint, porting the skip rules from the Go
  translators verbatim (no-MAC, `off_segment`, no-evidence, ambiguous-model suppression). Decoders
  emit observations only and MUST keep `metadata["mac"]` populated — `census_anchorable_mac?/1`
  reads it
- [x] 2.5 `DiscoveryIngestor` stamps `agent_id`/`gateway_id`/`partition` from gateway-attested status
  metadata and `source`/`identity_source` from the registry; an add-on-supplied `agent_id` or
  `source` MUST NOT reach `SyncIngestor`. Test the hostile case explicitly
- [x] 2.6 Wire the `DISCOVERY_V1` branch into `StatusHandler.publish_package_telemetry_record/3`
- [x] 2.7 Golden-fixture tests: the Elixir decoders produce byte-identical update maps to the 1.5
  fixtures

## 3. netprobe serves AddonService

- [x] 3.1 Add `addon-sdk` to `rust/netprobe`; bind a second socket post-`--drop-user` and serve
  `AddonService` via `serve_on_listener(addon, listener, None)`. Implement `Info` / `Configure` /
  `Health`. Legacy `NetprobeFrame` socket untouched
- [~] 3.2 **SO_PEERCRED WILL NOT BE IMPLEMENTED -- it is a no-op here, and the reason is worth
  keeping.** Mode 0600 owned by the runtime user already excludes every uid except that user and
  root, so the entire marginal population a uid allowlist would add is root -- and root defeats a
  uid check with one `setuid` before `connect`. It would also reject clients that work today (a
  `sudo` dev loop, `sudo grpcurl -unix` for triage) and reject them invisibly.

  What the mode does NOT do is distinguish THE AGENT from any other process running as the same
  user -- and on the shipped units those ARE the same user (`User=serviceradar` in the agent unit;
  `--drop-user serviceradar` in netprobe's). Only mutual authentication separates them. The SDK
  implements mTLS (`addon_sdk::tls::build_server_mtls`, `serve_on_listener(.., Some(tls))`), but it
  is fed by go-plugin's AutoMTLS handshake and netprobe is systemd-supervised rather than
  agent-launched -- there is no handshake to carry a cert. Closing that needs cert distribution for
  a supervised add-on, which is a change of its own, not a line in this one.

  DONE instead: the mode is now PINNED by tests (`the_addon_socket_is_owner_only`,
  `binding_over_a_stale_socket_succeeds`) and the reasoning is recorded at
  `restrict_socket_permissions`. The mode is the whole access control on this socket, it was set by
  one unguarded line, and nothing stopped a umask change or a refactor loosening it silently.

  Original text: Socket mode landed -- the socket is bound after `--drop-user` and chmod'd
  0600 (`addon_service.rs:595`, verified on alma-test01 as `srw------- serviceradar serviceradar`).
  `SO_PEERCRED` is NOT implemented: zero references in `rust/netprobe/` or `rust/addon-sdk/`. Mode
  0600 means only the owner and root can connect, which is most of the value, but the peer's
  identity is never checked -- so anything running AS the runtime user reaches Configure and
  RunCommand. Enforce peer identity on the new socket with `SO_PEERCRED` plus socket mode. The current
  IPC socket has no peer check at all; `AddonService` exposes `Configure` and `RunCommand`, so this
  ships in the same PR that binds the socket
- [x] 3.3 Carry `running_as_root` and the p0f/muonfp/recog/satori corpus revisions from `PingAck`
  onto `AddonService.Health`, and repoint `push_loop_capabilities.go:224-270` at it. Without this,
  deleting the IPC silently turns banner-grab capability reporting off
- [x] 3.4 Emit census and mDNS as `DISCOVERY_V1` over `StreamTelemetry`; collapse
  newest-per-interface in netprobe rather than the agent
- [x] 3.5 Verify `//rust/netprobe:static_linkage_test` still passes on x86_64 AND aarch64 musl with
  the new dependency closure (`rustls`/`ring`/`rcgen`); no `PT_INTERP`, no `DT_NEEDED`
- [x] 3.6 Bump `addons/netprobe/addon.yaml` version and `NETPROBE_VERSION`; register
  `rust/addon-sdk/*` under netprobe's `path_belongs_to_addon` in
  `scripts/check-native-addon-version-bumps.sh` (powerdns has the same gap — fix both); run
  `bazel test //build/native_addons:build_gates_test`
- [x] 3.7 Confirm what an `AddonService`-serving netprobe reports as state/active and that
  `addon_rollout_eligibility.ex` `supervision_state_ready?` accepts it — `tolerated_failures: 0`
  means one target that cannot report health fails the rollout for the whole fleet

## 4. Config path

- [x] 4.1 Specify and implement the config path before its transport is deleted: `AddonService.Configure`
  replaces the `ApplyConfig` IPC arm; define what still writes the bootstrap file (where
  `enabled:false` is terminal until restart) and how the two restart-only fields
  (`capture_interfaces`, `flow_table_max_entries`) are handled
- [x] 4.2 Update the cross-language config contract fixtures that pin this:
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
- [~] 5.4 **PRODUCERS AND DECODERS DONE; THE DELETION IS BLOCKED ON 5.5.** Shipped: goldens
  captured from the Go translators before anything was removed (#3981); the three schemas
  registered with Elixir decoders proven key-for-key against them (#3982); the process decoder's
  subject moved into its payload plus a guard refusing a multi-part snapshot that would overwrite
  rather than reassemble (#3990); `collector_ip` plumbed agent -> netprobe, without which netprobe
  can neither choose a DPI subject nor name the host a process listing describes (#3991); and
  netprobe emitting all three as `DISCOVERY_V1` while ceasing to write them on the legacy IPC
  socket (#3995, #3996). All three MOVED rather than dual-emitted, because the add-on ships
  independently of the agent.
  Still open: delete `netprobe/translator.go` and the netprobe half of
  `push_loop_mapper_netprobe.go`. Blocked because the agent's own banner-grab handler injects
  ACTIVE fingerprints into the same sidecar queue (`banner_grab_handler.go:102`
  `EnqueueFingerprintEvent`), so the translator still has a live producer. See 5.5.
  Note the drain split needs no code: `EnqueueFingerprintEvent` writes to the AGENT-LOCAL channel,
  so with netprobe no longer sending passive fingerprints over IPC, that channel now naturally
  contains only the agent's own active ones.
  Original text: Move DPI, fingerprint and process snapshots onto `DISCOVERY_V1`; delete
  `netprobe/translator.go` and the netprobe half of `push_loop_mapper_netprobe.go`. Process snapshots
  gain real snapshot semantics, fixing today's partial-fragment device updates (netprobe splits them
  across frames with no chunk fields)
- [x] 5.5 **DONE.** Banner matching is served over `AddonService.RunCommand` and the filters now
  live in netprobe. `BannerBatch` was the last functional request/response arm on the bespoke
  socket, so this is what makes retiring it possible.

  Shipped:
  * netprobe implements `Addon::run_command` for `action_id: "match_banners"` under
    `schema: "serviceradar.netprobe.banner_match.v1"` (`rust/netprobe/src/banner_command.rs`).
    The schema is CHECKED, not ignored: a payload naming a shape this build does not implement
    is refused rather than decoded as v1 and answered confidently about.
  * The filters moved in, which as predicted meant deleting the padding: `match_banner_batch`
    now returns only real matches and `unknown_match` is gone. The response is no longer
    positionally 1:1 with the request -- callers already joined on `observation_id`, so nothing
    downstream changed. Both transports benefit; the IPC arm returns the shorter batch too, and
    an old agent's now-redundant filter is harmless.
  * The agent gained the RunCommand client the task noted did not exist
    (`go/pkg/agent/netprobe/addon_command.go`), on the SAME socket the telemetry pump uses so
    the two cannot drift.
  * Skew is handled as required: `Sidecar.MatchBanners` tries RunCommand and falls back to the
    IPC arm. `addons/netprobe/addon.yaml` declares `base_agent: ">=1.2.0"` -- a floor -- so a new
    agent against an old netprobe is a supported deployment, not a rollout transient.

  Two decisions worth not re-litigating:
  * **Only the three fields the matcher reads travel** (`observation_id`, `protocol`, banner
    bytes). `host`/`port`/`source`/`observed_at` stay on the agent, which re-attaches them when
    building the fingerprint event. `observed_at` is the sharp one: nanoseconds since epoch
    exceed 2^53, so any consumer parsing JSON numbers as doubles truncates it silently. Adding a
    field later is additive and costs no schema bump. Pinned by a test.
  * **Banner bytes ride as base64, not as a JSON string.** The matcher lossily converts to UTF-8
    itself, so a string looks equivalent -- but Go replaces each invalid BYTE with U+FFFD while
    Rust's `from_utf8_lossy` replaces each invalid SEQUENCE with one. They disagree on exactly
    the binary banners (SMB, RDP, DNS, NTP) this path exists to identify, and the disagreement
    would surface as a corpus match quietly changing rather than as an error. Go's
    `encoding/json` emits standard-padded base64 for `[]byte`, which is byte-identical to what
    Rust's `STANDARD` engine decodes.

  Still open, and NOT part of this task:
  * The IPC `MatchBanners` arm and the fallback in `Sidecar.MatchBanners` may only be deleted a
    release AFTER the netprobe implementing RunCommand has converged across the fleet.
  * **This still does not unblock the 5.4 translator deletion, exactly as predicted** -- but the
    reason is now narrower than "a new core schema is needed". The agent still runs
    `bannerMatchToFingerprintEvent` -> `EnqueueFingerprintEvent` -> `s.events` -> `DrainEvents`
    -> `translator.go`. That queue is AGENT-LOCAL and, since 5.3/5.4 stopped netprobe writing
    passive fingerprints over IPC, it now contains ONLY the agent's own active banner-grab
    fingerprints. So it is no longer netprobe IPC in any sense -- it merely LIVES in
    `go/pkg/agent/netprobe/`. What 6.1 needs is a RELOCATION of that queue and `translator.go`
    into the agent package, not a second registered schema. Registering
    `sweep_active` fingerprints as their own DISCOVERY_V1 schema remains a separate, optional
    change; do not do it as a side effect of the deletion.

  Original analysis, verified 2026-08-24 and kept because each point was acted on:

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

- [~] 5.6 **AUDITED 2026-08-25: DO NOT MOVE FLOW ATTRIBUTION ONTO THE RELAY.** The codegen half is
  done (kept below); the transport half should not be built as written.

  **The premise is false.** Flow attribution already owns an ordered pending prefix and removes it
  after positive receipt. `push_loop_flow_attribution.go` names the local terminal-removal helper
  `quarantineFirst`, but `harden-flow-attribution-pipeline` clarifies that invalid identical bytes are
  poison-dropped with bounded telemetry and are not copied into a quarantine queue or store. That
  change also owns the gateway's current false-ack gap and its truthful negative acknowledgement;
  moving the bytes to another relay would not solve either boundary.

  **The move would make delivery WORSE, in two specific ways.**
  1. It downgrades the durability terminus. Today the agent's ack returns only after the CNPG UPSERT
     commits. The relay's ack returns after `Gnat.pub` -- core NATS, fire-and-forget, **no JetStream
     PubAck**. The "acked relay" is an at-least-once transport ending in an at-most-once publish.
  2. It adds a silent drop-and-ack hole. `otlp_relay_publisher.ex` `route/2` handles only OTLP payload
     kinds; anything else hits `defp route(_kind, _subjects), do: :error`, whose branch logs a warning
     and returns `{:cont, :ok}` -- the record is DISCARDED and the batch still acks. Flow attribution
     today fails closed instead.

  **The JetStream-first hard rule does not compel it, and the move would not satisfy the rule anyway.**
  The data does land in CNPG directly (`status_handler.ex` -> `flow_attribution.ex` -> `persistence.ex`
  raw multi-CTE INSERT), so the rule is not met literally. But the rule's stated rationale is that "a
  metric that lands straight in a hypertable is invisible to every real-time consumer until it is
  queried back out" -- and `flow_process_attribution_current` is NOT a hypertable and not a time
  series. It is a plain last-write-wins current-state table whose only consumer is an in-DB SQL
  correlator on a 120s cycle over a 15-minute window. No real-time subscriber is being starved,
  because there is nothing here to subscribe to. And routing it through the relay would satisfy the
  rule's letter while leaving no consumer (no `event_writer` processor exists for it) and no delivery
  confirmation. **Whether this whole class of current-state writes -- flow attribution, workload
  identity, plugin results -- is in the rule's scope is a question for a human to settle once, not
  something to resolve by bolting one payload onto a relay that does not itself satisfy the rule.**

  **It unblocks nothing today.** 5.6 exists as a precondition for 6.1, so flow attribution is not
  demoted to the lossy `StreamTelemetry` path when the bespoke IPC is retired (`design.md`, "Loss
  semantics"). 6.1 lands only after 5.1-5.7 are confirmed in the fleet, and 6.2 is still blocked on a
  release shipping without the legacy census producer. Doing 5.6 now ships risk with no payoff.

  **Prerequisites do not exist either.** netprobe implements only `info`/`configure`/`health`/
  `stream_telemetry` -- no `relay_otlp`, so it inherits the SDK's `unimplemented` default -- and it has
  no durable spool. The only spool is ~2,400 lines inside the otel crate, coupled to
  `OtlpRelayFrame`/`TelemetryBatch`; reusing it means extracting a shared crate first.

  **If any part is ever built, build only the minimal one:** parameterize the relay pump's identity
  triple (`addon_otlp_relay.go` hardcodes `otlp-relay` / `otel-collector` / `otlp-relay`) and extend
  the gateway's payload-kind route table, WITHOUT moving flow attribution. Three designs were scored by
  three judges on different lenses; safety preferred a staged variant and reversibility the minimal
  one, but the value-lens judge conceded the minimal design "moves constants around and says so."
  That is the honest summary: there is little to win until 6.1 is actually close.

  **Two real defects WERE found in the current path, and they are the work worth doing instead.** Both
  are filed rather than fixed, because the obvious fix for the first reintroduces a problem that was
  already fixed once:
  * GitHub #4030 -- delivery has only two outcomes: false-ack, or tear down the agent's whole status
    stream. `5a4bbf9fd3` (Jul 11) removed flow attribution from `should_buffer?` precisely to avoid the
    false ack; `33b1b9ba54` (Jul 20) put it back because a core outage was tearing down the agent's
    entire stream. Both are right. The resolution is a third outcome -- `received: false`, which the
    protocol expresses and the agent already handles, but which the gateway hardcodes to `true`.
  * GitHub #4031 -- flow-attribution persistence runs INSIDE the singleton `StatusHandler`'s
    `handle_call`, serialising every other status on that node behind a multi-CTE UPSERT of up to 4096
    rows. The same function already carves out endpoint inventory to a bounded admission queue, with a
    comment naming this exact hazard. Do NOT fix it by making the call asynchronous -- the synchronous
    reply is what makes the ack mean "committed".

  Note the audit also produced one claim that did NOT survive checking, recorded so it is not repeated:
  that the add-on Configure path defaults `flow_attribution_ipc_batch` to the non-batched arm. The
  observation is real (`addon_config_json.rs` uses a bare `#[serde(default)]` on `bool`, i.e. false,
  against `true` in `config.rs`), but `ConfigSchema.normalize_params/2` injects schema defaults at
  author time and `ApplyAddonConfigDefaults` runs it on the assignment, profile, policy and seeder
  paths. Latent inconsistency, not a live bug.

  **The codegen half is DONE, and it was smaller than this task assumed.** The task says to "add real
  generation for `flow_attribution_event.pb.ex` in the same change". No generation had to be added:
  `Serviceradar.Agent.Netprobe.V1.{WorkloadIdentity,FlowAttributionEvent,FlowAttributionEventBatch}`
  were ALREADY generated into `netprobe.pb.ex`, and the hand-mirrored file was a second copy of the
  same three messages under a different module namespace. Compared field by field before touching
  anything: all 20 `FlowAttributionEvent` fields, all 15 `WorkloadIdentity` fields (including both
  map entries) and all 4 batch fields matched the proto and each other exactly -- so the copy had not
  yet drifted, and the swap cannot change decoding, since protobuf decoding depends only on field
  number and type.
  Removed: the duplicate, plus `lib/netprobepb.ex`, which existed ONLY as a `Boundary` shell to stop
  the compiler warning that the hand-written structs were "not included in any boundary" -- not as a
  wrapping abstraction, so removing it does not touch the "wrap third-party APIs" rule. The generated
  modules already have their own shell (`lib/serviceradar_agent_netprobe_v1.ex`) and were already in
  the root boundary's `deps`, which is why the swap needed no boundary change beyond deleting the dead
  entry.
  Left for the rest of 5.6: generalizing `RelayOtlp`'s identity constants
  (`go/pkg/agent/addon_otlp_relay.go:48-50` hardcodes `otlp-relay` / `otel-collector` / `otlp-relay`)
  and the gateway's `otlp_relay_publisher.ex` routing for the signals that use that relay. Flow
  attribution remains on its dedicated ordered-prefix/`StreamStatus` path; its TCP correctness,
  bounded core admission, and truthful negative acknowledgement are owned by
  `harden-flow-attribution-pipeline`.

- [~] 5.7 **AUDITED 2026-08-25; ALL THREE ARMS STAY. Do not delete on the strength of this task's
  original wording -- two of its three claims are false, and the third is a live product decision that
  went the other way.** Ten agents swept go/, rust/, elixir/, proto/, docs/, helm/, addons/,
  openspec/ and git history; each "dead" verdict then faced three independent skeptics (production
  reachability, operator surface, version skew). Findings, each verified against the source by hand
  afterwards rather than accepted:

  * **tag-21 `flow_attribution_event` is LIVE. Not deletable, and the premise is wrong.**
    - It is the `else` arm of a live runtime branch at `rust/netprobe/src/server.rs:200-212`, selected
      by `flow_attribution_ipc_batch`, reached on every drained eBPF attribution event.
    - **It is an operator-documented escape hatch**, not an internal fallback:
      `addons/netprobe/config.schema.json:54-60` renders it as an admin toggle ("Disable only for
      debugging older agents or framing issues") and `docs/docs/netprobe.md:130` repeats the advice.
      Deleting the branch while the toggle survives means an operator can select a mode whose
      implementation is gone, and `addon_service.rs` still answers `accepted: true` -- this repo's own
      "job reported success while writing nothing" failure shape.
    - **Skew is measured, not hypothetical:** five published netprobe tags (0.2.3 x2, 0.2.5 x3) predate
      the batching commit `34e551432e` and emit tag 21 exclusively, verified by
      `git merge-base --is-ancestor`, not by version-string comparison. The agent has no minimum-peer
      check, `framing.go` uses plain `proto.Unmarshal`, and the `readLoop` has no default branch -- so
      deleting the consumer at `client.go:554-556` is SILENT total loss of flow attribution for those
      hosts: no log, no metric, no `recordEventDrop`.

  * **`ExternalFlowRecord`/`ExternalFlowAck` are test-only in-tree and require coordinated cleanup.**
    - Confirmed: the only Go callers are `client_test.go`, and the Rust handler at `server.rs:490-506`
      is live code that no production sender can reach.
    - `harden-flow-attribution-pipeline` reconciles the active host-network-visibility requirement to
      the deployed agent-up/current-state/CNPG correlation path, so production no longer depends on
      this arm. Checked tasks 21.1/21.2 remain a record of the retired demo canary.
    - `addons/netprobe/config.schema.json:46-53` exposes `external_flow_match_window_ms` as an operator
      key that exists only to tune the matcher only this arm reads; the root schema is
      `additionalProperties: false`, so removing the property fails validation for every persisted
      `AddonAssignment.params` row still carrying it.
    - The Rust matcher is WRITTEN by the live eBPF attribution hot path (`attribution.rs:1865`) and READ
      only here -- so today it is a write-only map. Delete the arm and the matcher together or neither;
      `external_flow.rs:131` also owns `default_external_flow_match_window_ms()`, which
      `config.rs`/`runtime_config.rs` import, so deleting the file alone breaks bootstrap config parsing.

  * **`StartRemoteCapture`/`PcapngBlock` are genuinely dead CODE -- and deliberately reserved SPEC.**
    - Zero references outside generated bindings and openspec prose; not one test. Both messages carry
      zero fields (confirmed in the generated Elixir, which emits one `field` line per declared field).
    - But they are placeholders that `add-host-network-visibility-sidecar` task 4.1 `[x]` created ON
      PURPOSE, and its **unchecked Phase 5** ("Remote pcapng capture sessions", `tasks.md:242-260`)
      plus normative spec deltas (`specs/remote-packet-capture/spec.md:104,113,121`) are written against
      them by name. This is a conflict between two live proposals, not dead code.
    - **DECIDED 2026-08-25 (maintainer): Phase 5 is unfinished work, not abandoned. Leave the
      placeholders; they are OUT OF SCOPE for 5.7.** Tracked in GitHub issue #4025, which records what
      Phase 5 still specifies, what exists today (only the two zero-field messages), and the lookalike
      that must not be mistaken for progress -- `rust/netprobe/src/capture.rs` gates on a cargo feature
      named `remote-capture`, but that is the PASSIVE interface opener for fingerprinting/DPI, is off in
      every build, and touches neither message.

  **Cross-cutting, and required before ANY of these arms is removed:**
  * `NetprobeFrame` (`proto/agent/netprobe/v1/netprobe.proto:26-52`) has **no `reserved` statement at
    all**. The repo convention is well established and includes a comment naming what was removed --
    `proto/monitoring.proto:218,254,276,307,861,927-928`, and `netprobe.proto`'s own
    `VisibilityAgentConfig:118-121`. Reservations go on the enclosing MESSAGE; proto3 forbids them
    inside a `oneof` block.
  * **Nothing in CI would catch a missing `reserved`.** `buf.yaml` declares `lint` only, with no
    `breaking:` section, and `make proto-lint` is `buf lint`. A future field reusing a freed tag would
    be accepted silently and mis-decode against un-upgraded peers. Tracked as GitHub issue #4026, which
    also proposes a loud unknown-arm branch in the agent `readLoop` -- that one should land BEFORE any
    arm is retired, since it is what makes the retirement observable rather than silent.
  * Deleting any arm requires regenerating TWO committed trees -- `netprobe.pb.go` (`Makefile:623-625`)
    and `netprobe.pb.ex` (`Makefile:677`), the latter guarded by `verify-proto-elixir`
    (`Makefile:685-690`), a `git diff --exit-code` drift gate. Rust needs no committed change;
    `rust/netprobe/build.rs` regenerates via prost at build time.

  **Separately found, worth fixing on its own merits (NOT a blocker):** `flow_attribution_ipc_batch`
  and `emit_raw_flow_attribution_events` are parsed by two Rust structs with OPPOSITE defaults --
  `config.rs:11-12` defaults both to `true`, while `addon_config_json.rs:46-49` uses a bare
  `#[serde(default)]` on `bool`, which is `false`. An audit agent concluded from this that the
  non-batched path is the DEFAULT on the add-on Configure surface; **that conclusion is wrong and was
  checked** -- `ConfigSchema.normalize_params/2` injects schema defaults at author time
  (`config_schema.ex:78-80`) and `ApplyAddonConfigDefaults` runs it on the assignment, profile, policy
  and seeder paths, so `true` is materialized into stored params in the normal case. The divergence is
  latent, not live. It still deserves fixing: correctness currently depends on a THIRD component always
  injecting a default, and `ApplyAddonConfigDefaults` falls through unchanged when a package row has no
  `config_schema`. Make the Rust parser self-consistent with the schema, and pin it with a test.

  Original text: Delete the dead arms rather than porting them: `ExternalFlowRecord`/`ExternalFlowAck`
  (test-only callers), `StartRemoteCapture`/`PcapngBlock` (empty messages, no code), and the tag-21
  non-batched flow-attribution fallback (disabled by default)

## 6. Retire the bespoke IPC

- [ ] 6.1 Delete `go/pkg/agent/netprobe/` and the netprobe `oneof` arms; netprobe stops binding the
  legacy socket. Land only after 5.1-5.7 are confirmed in the fleet
- [ ] 6.2 **STILL BLOCKED as of 2026-08-24** -- re-checked, not assumed. `VERSION` is 1.4.42, the
  newest tag is `v1.4.42`, and `git cat-file -e v1.4.42:go/pkg/agent/push_loop_netprobe_census.go`
  still resolves, so the RELEASED agent still emits `netprobe-census`. Unblocks itself once a
  release ships without that producer. Full reasoning below.
  Retire the `@census_service_types` / `@mdns_service_types` `ResultsRouter` clauses and
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
- [x] 7.2 Elixir DB-backed tests (srql-fixtures lifecycle) -- PR #4002. Create-vs-enrich is now
  covered against a real database for every netprobe payload: the census CREATES; mDNS, DPI and
  process create nothing for an unknown subject and still enrich a device the census established;
  fingerprint's version already existed. Falsified by mutation -- emptying
  `enrichment_only_source?/1` fails exactly the three create-nothing tests. Added to
  `sync_ingestor_passive_netprobe_identity_test.exs` rather than a new file, because a new
  integration SOURCE has to be registered in `test/INTEGRATION_SOURCE_DISPOSITIONS.tsv` and
  hand-projected into `build/integration_test_dispositions.bzl`; reusing a source with the same
  disposition is one count (3 -> 9).
  Also fixed `discovery/ingestor_test.exs`, whose setup ran `start_supervised!(Buffer)` against the
  name `application.ex:126` owns. Note what that does and does NOT mean: that file is plain
  `ExUnit.Case`, so in the database-free unit tier -- where `test_helper.exs` never starts the
  application -- nothing owned the name and the tests passed, which is why CI was green. They fail
  only in a DB-backed local run. The setup now branches on `Process.whereis/1` (start when absent,
  `Buffer.reset/1` when the app owns it); a test-local name fixes neither world, because
  `DiscoveryIngestor` calls `Buffer.offer/1` with the DEFAULT name.
- [x] 7.3 e2e on `alma-test01` -> farm01. Staged netprobe 0.2.51
  (`//build/native_addons:stage_netprobe_addon`) and an agent from this branch
  (`//build/packaging/agent:stage_agent_rpm`) onto the lab host; rolled core + agent-gateway on
  farm01 (helm rev 119, digests `176f296c` / `33358f30`).
  PROVEN: netprobe serves `AddonService` on `addon.sock` at mode 0600 (the
  `restrict_socket_permissions` read-back guard); the agent pump attaches and RECONNECTS after a
  netprobe restart; core routes `TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1` to `DiscoveryIngestor`; and
  census + mDNS ingest live -- 39 census / 5 mDNS devices updated AFTER the rollout gate
  (last pod ready 21:09:32Z), which is the only window where old pods cannot be the explanation.
  NOT observed end-to-end: `fingerprint.v1` and `dpi.v1` produce nothing on this host because
  netprobe refuses AF_XDP on `ens18` (it carries the default route; redirect would black-hole
  host connectivity) -- a deliberate guard, not a gap in the contract.
  `process.v1` is SERVED and has a real producer (`FlowAttributionRuntime`, gated on
  `process_snapshot_interval > 0`), but nothing lands, and the cause is worth keeping:
  **the agent's `host_ip` is stale.** `/etc/serviceradar/agent.json` says `192.168.2.243` while
  the host is `192.168.1.171`; `push_loop_config.go:763` stamps that value verbatim as netprobe's
  `collector_ip`, and a process snapshot names its subject with it. On farm01 `192.168.2.243`
  matches 0 devices and `192.168.1.171` matches 1 -- so the payload is correctly DROPPED by the
  enrichment-only rule instead of minting an IP-squatting device. The policy is working; the
  input is wrong. Any DPI subject choice on that host is mislabelled the same way.
  ENRICHMENT-ONLY VERIFIED IN PRODUCTION, not just in tests: across farm01's entire device
  population including soft-deleted rows, 23 devices have ever carried `mdns.*` metadata and
  **0** of them lack `device_census.*` evidence (83 devices carry census evidence). Every device
  mDNS has ever touched was established by the census first, so mDNS has never minted one. The
  check is falsifiable -- a single mDNS-created device would make that second count nonzero.
  Two ordering facts e2e caught that no unit test did:
  (a) `collector_ip` is resolved ONCE per `StreamTelemetry` stream, so a pump that attaches before
      the first `Configure` leaves `process.v1` unserved for that stream's life.
  (b) "stream attached" only logs on the first DELIVERED batch, which waits for the census
      snapshot interval (~2 min) -- an attached-but-silent pump looks broken for that window.
- [ ] 7.4 **BLOCKED, and the blocker is now exact.** Three schemas went end-to-end
  (`fingerprint.v1`, `dpi.v1`, `process.v1`) with **zero agent and zero gateway changes** -- the pump
  forwards batches verbatim, which is the property this contract exists for. But each needed a NEW
  proto message for its payload, so the "zero proto changes" half is still unproven.

  **The acceptance test that would prove it is now fully designed** (investigated 2026-08-25), and it
  is one registry entry and nothing else:

  ```elixir
  "serviceradar.netprobe.fingerprint.active.v1" => %{
    source: "sweep_active",
    identity_source: "netprobe_fingerprint_active",
    policy_class: :enrichment_only,
    decoder: Decoders.Fingerprint          # the SAME decoder, reused unchanged
  }
  ```

  Zero proto changes (reuses `FingerprintEventBatch`), zero agent changes, zero gateway changes, and
  zero new decoder code. Nothing else in the repo demonstrates the property as sharply.

  **It cannot be added yet, and the reason is this module's own rule:** "Only schemas whose source
  string and identity_source are already decided by a SHIPPING PRODUCER are registered. Guessing a
  source here is not a harmless placeholder -- it is a guardrail pointed at the wrong thing." There is
  no producer for active fingerprints on `DISCOVERY_V1`. They are produced by the agent's banner-grab
  planner (`banner_grab/candidate_planner.go` sets `Source: SourceSweepActive`) and consumed by
  `netprobe/translator.go` on the AGENT-LOCAL path, never crossing the telemetry stream. So 7.4 is
  gated behind the same relocation 6.1 needs, not behind more design.

  **Two findings from that investigation, both traps for whoever does 6.1:**
  * `Decoders.Fingerprint` ALREADY discriminates active from passive -- `sweep_active?/1` keys on
    `profile_id == "sweep_active"` and `source/1` returns `"sweep_active"` instead of
    `"passive-netprobe"`. **That branch is dead code today**, written in anticipation of a producer
    that never arrived. Do not read its existence as evidence that active fingerprints already work.
  * Even when reached, the decoder's determination would be DISCARDED.
    `discovery_ingestor.ex` `stamp/3` -- commented "THE identity boundary. Nothing here reads the
    payload." -- does `Map.put("source", entry.source)`, overwriting whatever the decoder computed.
    That is deliberate: a payload must not be able to choose its own guardrail. The consequence is
    that routing active fingerprints through `fingerprint.v1` would silently file them as
    `passive-netprobe`, and the ONLY correct route is a second registry entry, exactly as above. This
    confirms the caution recorded in 5.5 rather than superseding it.

- [x] 7.5 **DONE.** `openspec validate refactor-netprobe-onto-generic-addon-contract --strict` ->
  "Change 'refactor-netprobe-onto-generic-addon-contract' is valid" (2026-08-25).
