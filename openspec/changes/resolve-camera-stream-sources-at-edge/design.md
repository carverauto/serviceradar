# Design: resolve camera stream sources at the edge

## Context

Evidence in code, as of `origin/staging` at `e07bffdfa9`:

**Writers.**

- Protect plugin. `buildProtectCameraDescriptors` copies the built URL into the
  descriptor `SourceURL` and each profile's `SourceURLOverride`, and the raw
  `rtsp_alias` and `rtsps_alias` into profile metadata
  (`go/cmd/wasm-plugins/unifi-protect/protect_descriptors.go:86-109`).
  `buildProtectStreamURL` puts the alias in the URL path
  (`protect_streams.go:47-68`). The integration API path reads full `rtsps://`
  URLs from `/proxy/protect/integration/v1/cameras/{id}/rtsps-stream`
  (`protect_snapshot.go:158-198`). The result details also carry the raw
  `cameras[].channels[]` with `rtspAlias` and `rtspsAlias`, plus `streams[].url`
  (`main.go:68-70`, `protect_types.go:67-72,127-131`).
- Axis plugin. It builds `rtsp://<host>/axis-media/media.amp?<params>` with no
  userinfo (`axis/main.go:823-839`) and copies it into the descriptor and the
  profiles (`main.go:545,560`). Credentials come from plugin config
  (`axis/rtsp_stream.go:13-14`).
- Core ingest. Results arrive through `Edge.Projectors.WasmPluginResult`
  (`wasm_plugin_result.ex:151`, passing `details` through at `:339`) or through
  the legacy `Ingestion.ResultIngestor`, and both reach `PluginResultIngestor`
  (`plugin_result_ingestor.ex:74,152`).
  - That module stores the whole reported payload in `service_status.details`
    (`:754-781`) and in `service_state.message` (`:648`).
  - It then runs `Camera.InventoryIngestor` (`:2312`). That module writes
    `source_url` (`inventory_ingestor.ex:294`), `source_url_override`
    (`:370-377`), profile metadata (`:384`), device metadata `camera_source_url`
    and `camera_metadata` (`:561-567`), and source metadata `device_enrichment`,
    which includes `streams[].url` (`:1714-1730`).
  - Generic enrichment descriptors take any URL verbatim (`:1735,1764,2234`).
- Writes go only through `Source.upsert_source` and `StreamProfile.upsert_profile`
  (`:434-443`). Both resources allow create and update only for the system role
  (`stream_profile.ex:85-87`, `source.ex:111-112`). No raw SQL writes these
  tables, and no UI or API lets an operator type a stream URL.

**Readers.**

- Needs the address: `RelaySourceResolver.require_source_url`
  (`relay_source_resolver.ex:59-71`). It feeds `AgentCommandBus.start_camera_relay`
  (`agent_command_bus.ex:1030-1043`), and that feeds the agent's native gortsplib
  reader (`go/pkg/agent/camera_relay_rtsp.go:74-99`).
  `normalize_camera_relay_start_payload` (`agent_command_bus.ex:1427-1440`) drops
  `plugin_assignment_id`, so Core never selects the Wasm stream path
  (`camera_relay.go:515-531`).
- Needs only the scheme: the device page TLS-bypass button
  (`device_live/camera_components.ex:351-370`) and the God View button
  (`rendering_selection_methods.js:153-158`). The God View one is never shown:
  the server payload omits the URL (`god_view_stream.ex:2033-2076`).
- Loads the address but does not need it: device page assigns, where
  `normalize_camera_sources_for_display` keeps `source_url` and whole profile
  structs (`camera_components.ex:281-300`); `camera_data.ex:9`;
  `camera_multiview.ex:26,57`; the recording settings list;
  `EventIngestor.read_source` (`event_ingestor.ex:397-405`); and AshAdmin
  (`ServiceRadar.Camera` has `admin show?(true)`). Reading `Source` requires
  only `devices.view`.
- Exposes a copy to users: `in:devices` returns device `metadata`
  (`rust/srql/src/models/inventory.rs`, `DeviceRow.metadata`), and the service
  pages read `service_status.details`. SRQL `in:camera_sources` already omits
  both columns (`rust/srql/src/query/camera_sources.rs:7-9,85-111`).
- Outside the database: JetStream edge-record streams and the edge-record DLQ,
  which keeps exact bytes and has no MaxAge (`docs/edge-record-dead-letter-runbook.md`),
  and CNPG backups.

**Credential model.**

- The Protect and Axis manifests already provision credential-rule consumers
  for the `camera_inventory` and `camera_stream` purposes, with broker grants
  (`unifi-protect/plugin.yaml:91-180`, `axis/plugin.yaml`). So the discovering
  assignment holds the integration credential through the unified model.
- Direct typed references exist. `RecordingArchiveSettings.writer_credential_secret_id`
  is the closest precedent. It has a restrictive FK
  (`20261115210000_add_camera_nvr_operator_settings.exs:124-143`), an entry in
  `CredentialUsage` (`credential_usage.ex:292-321`), guarded deletion through
  `GuardCredentialDestroy` (`changes/guard_credential_destroy.ex:38-39`), and a
  web-ng usage route (`credential_inventory_components.ex:457`). The SNMP profile
  reference uses `on_delete: :nilify_all`
  (`20260521170000_add_snmp_credential_secret_refs.exs:8-15`), so it is not a
  restrictive precedent.

## Goals / Non-Goals

- Goals: no stream secret at rest in Core and none readable through any Core
  surface; streaming keeps working through the native agent reader; existing
  copies are removed and the removal can be verified.
- Non-goals: changing the Wasm `stream_camera` media path; adding an operator
  form for hand-entered stream URLs (none exists); purging JetStream or backups
  automatically.

## Decisions

### D1. Do not store the stream secret; resolve it at the edge when a stream opens

Must the secret be stored at all? No, as long as the discovering plugin can
re-derive it.

- Protect. The address can be re-derived from the inputs the inventory
  assignment already holds: the controller host (assignment param), the API key
  (broker grant), the camera id (`vendor_camera_id` = Protect camera id, falling
  back to the MAC, `protect_descriptors.go:40-41`), the quality or channel
  (`vendor_profile_id`: `high`, `medium`, `low` or `package` on the integration
  path, the channel id on the bootstrap path), and `rtsp_port` (default 7447) for
  the bootstrap path. The calls are
  `GET /proxy/protect/integration/v1/cameras/{id}/rtsps-stream`, falling back to
  the bootstrap `channels[].rtspAlias`.
  `resolveProtectStreamSourceURL` (`protect_streams.go:10-45`) already does this
  re-derivation for the Wasm stream path.
- Axis. The address carries no secret. The resolver rebuilds it and puts the
  plugin's credentials in the URL userinfo, which the native reader already
  uses for RTSP authentication.

The open flow:

1. Core sends `source_resolver = {plugin_assignment_id, vendor_camera_id,
   vendor_profile_id}` and no `source_url`.
2. The agent calls the assignment's plugin on demand. It uses the existing
   on-demand execution path (`PluginManager.RunPluginVerbForAssignment`,
   `plugin_runtime_manager.go:1391`), with the assignment's own params and
   standing grants, and a request document
   `serviceradar.camera_source_resolution_request.v1`.
3. The plugin returns `serviceradar.camera_source_resolution.v1`
   (`{url}` or `{failure_class, failure_detail}`). `url` is the only channel
   for the address and any credential; it may carry userinfo. The agent captures
   it in memory and never queues it as a plugin result.
4. The native reader opens the stream with it as its `SourceURL`.

That in-memory URL, for the life of one relay, is the only place a full stream
address exists. Nothing in Core, the credential store or the agent's disk holds
one.

`discovery_assignment_id` is the host-stamped assignment id from the result's
provenance (`PluginResultProvenance`). The ingestor records it on the source.

The resolver never creates or enables a stream on the controller. A disabled
channel is `source_not_found`. There is no cache: each open or reconnect costs
one controller request on the integration path.

Rejected alternatives:

- Store the secret in `network_credential_secrets` with a direct reference from
  the profile. The secret is machine-discovered and rotates on the controller,
  so a stored copy goes stale and still needs a sync writer. That gives the
  smallest benefit for the full five-condition cost of the hard rule.
- Switch to the existing Wasm `stream_camera` path. It already re-derives the
  address, but its RTSP client handles only interleaved TCP with a single H264
  track (`unifi-protect/rtsp_stream.go:129-185`), while the timestamp, dedup and
  TLS fixes live in the native reader. That would change the media path inside a
  security fix.
- Have Core resolve the address. Core cannot reach edge controllers.

### D2. One reduction rule, applied once, where results enter Core

The rule, `ServiceRadar.Camera.StreamAddressReduction`:

- An `rtsp://` or `rtsps://` URL is replaced by its origin
  (`scheme://host[:port]`).
- Any other URL loses its userinfo.
- Keys named `rtsp_alias`, `rtsps_alias`, `rtspAlias` or `rtspsAlias` (any case)
  are removed.

It walks the payload recursively, and for every string value:

1. If the string itself parses as JSON (an object, array or string), it is
   decoded, the decoded value is reduced by this same rule, and the result is
   re-encoded in place. Nesting is followed to a depth of 4; a value still
   JSON-encoded beyond that depth is replaced by the marker `"[reduced]"`, never
   left unreduced.
2. Then the URL rules above are applied to the string. For detection, JSON
   solidus escapes (`\/`, `\u002f`, `\u003a`, `\u0040`, in any letter case)
   are first normalised to `/`, `:` and `@`. A reduced URL is written back in
   unescaped form.

This is the only definition of "reduced"; the ingest path, the D7 scrub and
`pending/0` all call the same function.

`PluginResultIngestor.ingest_durable/3` and `ingest/2` apply the rule to the
whole result before anything else, with no exemption. Everything persisted or
passed on is built only from the reduced result: `service_status.details`,
`service_state.message` and `service_state.details`, edge-record handling, every
handler, the profile, source and device metadata that `InventoryIngestor`
writes, events and logs. None of them sees the secret, whatever the agent or
plugin version. The status payload digest is computed over the reduced payload.
From Stage 3 the ingestor sets `source_origin` from the reduced result: the
descriptor's `source_origin` field, or else the rule's origin function applied
to its URL field (an older plugin's address, already reduced to an origin).

Stage 1 ingest rule (Stages 1 and 2 only, while Core still writes the two relay
columns). On arrival the entry point derives two values from each plugin result:

- (a) The relay address extract, `ServiceRadar.Camera.RelayAddressExtract`,
  taken from the unreduced result. It holds only, per camera (`vendor`,
  `vendor_camera_id`), the value destined for `camera_sources.source_url`, and
  per profile of that camera (`profile_name`), the value destined for
  `camera_stream_profiles.source_url_override`. It is built with
  `InventoryIngestor`'s own descriptor normalization, so cameras and profiles
  match exactly as the upserts match them.
- (b) The reduced result, as above.

The two column writes take their values only from (a), through one function,
`InventoryIngestor.put_relay_addresses/2`. It is the only setter of those two
attributes; nothing built from (b) sets them. A camera or profile that the
result reports without an address gets null in that column, as today. (a) lives
only for that ingest call. It is never persisted, logged, put in an event, error
or command result, or passed to any other handler, and an error path reports its
keys, never its values. Stage 3 deletes `RelayAddressExtract` and
`put_relay_addresses/2`.

Profile metadata is also filtered against an allowlist (`source`, `width`,
`height`, `fps`, `bitrate`, `auth_mode`, `credential_reference_id`, `protocol`,
`insecure_skip_verify`), so a new vendor key cannot carry a secret through.

### D3. Data model

- `camera_stream_profiles`: `source_url_override` is removed. `source_origin`
  (text, origin only) is added. A `source_scheme` calculation is exposed for the
  UI.
- `camera_sources`: `source_url` is removed. `discovery_assignment_id` (uuid,
  references the plugin assignment, set to null when the assignment is deleted)
  is added.
- Device metadata no longer gets `camera_source_url`.

No new credential reference is added, so the hard rule's five conditions for a
direct reference do not arise. Every credential stays where it already is: in a
credential rule materialized into the plugin assignment. If a hand-entered stream
credential is ever needed, follow the `RecordingArchiveSettings` precedent from
the Context section.

### D4. Field exposure

Once the columns are gone and D2 is in place, Core holds nothing that could be
exposed. Until then (Stage 1), both columns are `public? false`,
`sensitive? true` and `select_by_default? false`, and only the relay resolver
selects them explicitly. Readers use `source_scheme`. The agent never persists
or logs the resolved URL (including its userinfo) and never puts it in a command
result or an error. Failure detail goes through PR #6703's sanitizer.

### D5. Failure modes

These classes are added to PR #6703's relay failure classes and shown to the
operator as sentences:

- Core, before dispatch:
  - `agent_upgrade_required`: the agent lacks the `camera_source_resolution`
    capability.
  - `source_resolver_missing`: the source has no `discovery_assignment_id`.
- Agent:
  - `source_resolver_unavailable`: the assignment is not loaded on the agent.
  - `source_resolver_unsupported`: the plugin did not return a resolution
    document, for example an old plugin version.
  - `source_not_found`: the camera or profile is unknown to the controller, or
    RTSP is disabled for it.
- Controller errors reuse the existing classes (`authentication_failed`,
  `connect_*`, `tls_*`, `dns_failure`).

### D6. Version skew

- Old agent, new Core: Core does not dispatch and reports
  `agent_upgrade_required`. Streaming on that agent pauses until it is upgraded.
  This is a deliberate hard cut; see Open Questions.
- New agent, old Core: the agent still accepts `source_url` when the command has
  no `source_resolver`. That legacy branch is removed together with the column
  drop (Stage 4).
- Old plugin, new agent, Core from Stage 3: the open fails with
  `source_resolver_unsupported`. Before Stage 3, Core sends the stored address
  and the agent's legacy branch opens it.
- New plugin, Core before Stage 3: no D8 key, so the plugin reports addresses
  as before. The D2 Stage 1 ingest rule keeps the two columns filled and the
  relay opens from them.
- New plugin, Core from Stage 3: the D8 key is present, so the plugin reports no
  address.
- Old plugin, Core from Stage 3: the plugin ignores the D8 key and keeps
  reporting addresses. D2 reduces them at entry, and nothing writes the two
  columns.
- Old Core replicas during the rollout keep writing copies. The cleanup in D7
  handles that, and holds each target until no older node remains.
- During the Stage 3 rollout, a Stage 3 node already delivers the D8 key while a
  Stage 1 node may still ingest the resulting origin-only report and open relays
  from the two columns. For a camera whose report took that path, a relay opened
  by a Stage 1 node finds no address until the rollout ends. No address is
  written; streaming is interrupted for that window. See Open Questions.
- Release ordering: camera plugins are upgraded before Core Stage 3; otherwise
  streams stop with `source_resolver_unsupported` until the plugin is upgraded.
- Release ordering: a Stage 4 agent requires Core at Stage 3 or later, because
  it no longer accepts `source_url`.

### D7. Cleanup of existing data

`ServiceRadar.Camera.StreamSecretScrubWorker` follows PR #6703's
`AgentCommandRecordScrubWorker` pattern:

- A migration only inserts the Oban job (`serviceradar:allow-startup-maintenance`)
  and bumps `core.migrations.expectedVersion`.
- The worker applies the D2 rule in Elixir, so the cleanup and the runtime cannot
  drift.
- It works in primary-key batches, one row per statement, keyed by each
  table's real primary key: `id` for `camera_stream_profiles`, `camera_sources`
  and `service_state`; `uid` for `ocsf_devices`; and
  `(timestamp, gateway_id, service_name)` for the `service_status` hypertable.
  It skips rows that changed since it read them, and it is idempotent.

Targets. This ordered list is the single definition of what the worker scrubs
and what `pending/0` checks; each target is tagged with the stage that brings it
into scope, and the running code version evaluates only the targets in scope
for it:

1. [Stage 1] `camera_stream_profiles.metadata`: reduce, and drop
   non-allowlisted keys.
2. [Stage 1] `camera_sources.metadata`: reduce.
3. [Stage 1] `ocsf_devices.metadata`: drop `camera_source_url`, and reduce the
   rest, including `camera_metadata`.
4. [Stage 1] `service_status.details`, `service_state.message` and
   `service_state.details`: reduce, and recompute the reported marker's payload
   digest with the ingest function.
5. [Stage 3] `camera_stream_profiles.source_url_override`: set `source_origin`
   from it with the D2 origin function, then null it.
6. [Stage 3] `camera_stream_profiles.source_origin`: reduce.
7. [Stage 3] `camera_sources.source_url`: null.

"Reduce" means the D2 function. A row counts against a target exactly when
that target's scrub would change it: for a reduce target, when D2 (plus the
allowlist on target 1) is not a no-op, so an origin never counts and a path,
userinfo on any scheme, or an alias key always does; for targets 5 and 7, while
the column is non-null. Stage 1 deliberately leaves targets 5 and 7 in place for
the relay opener, and `source_origin` does not exist before Stage 3. Stage 4
drops the two columns and removes targets 5 and 7 from the list.

Termination: a pass scrubs a target only while every connected Core node
reports, over `:erpc`, a scrub stage no lower than that target's stage (the
stage of the code the node runs; a node without the worker counts as stage 0).
Otherwise the pass skips that target. After each pass that changed in-scope rows
or skipped a target, the worker schedules another pass
`camera_stream_scrub_repass_seconds` later (runtime setting, code default 600).
It finishes only after a pass that scrubbed every in-scope target and changed
nothing. Without the stage check, an older replica still running during the
rollout can write a copy after the last zero pass: a node from before Stage 1
writes every copy, and a Stage 1 node writes the two columns that Stage 3
brings into scope. Every rolling deploy goes through that window, so it is not a
theoretical race. Holding targets 5 and 7 until no Stage 1 node remains also
keeps a Stage 1 node from opening a relay from a column already nulled. The
worker logs counts per pass and emits one completion event.

Following "close the path before deleting", the reduction ships in the same
stage as each cleanup run.

Operator verification. The worker exposes `pending/0`, which returns two
things:

- `in_scope`: per in-scope target, the count of rows that count against it
  under the rule above. Completion means every one is zero, and the worker's
  last-pass check is this same count.
- `at_rest_until_stage_3`: while targets 5 and 7 are not yet in scope, the
  count of rows with a non-null `source_url` and with a non-null
  `source_url_override`, reported by column name. It never blocks completion;
  it exists so that a Stage 1 result (`in_scope` all zero, addresses still at
  rest in those columns) cannot be mistaken for the fix. From Stage 3 it is
  absent.

The operator runs it with
`bin/serviceradar_core_elx rpc 'IO.inspect(ServiceRadar.Camera.StreamSecretScrubWorker.pending())'`.
This is the only verification the spec and the runbook refer to; there is no
separate SQL proof.

Out of band, and documented for operators: JetStream source streams age out
under their retention, DLQ entries for plugin-result batches must be purged by
the operator, and backups expire under backup retention. Every Protect alias
that was stored was exposed, so operators should regenerate them by turning RTSP
off and on in Protect.

### D8. Inventory address cutover signal

Plugins keep reporting stream addresses in inventory results until Core has cut
over. Until Stage 3, Core opens relays from the two stored columns, and every
inventory upsert writes them (`inventory_ingestor.ex:294,370-377`; both upsert
actions accept the fields, including null). An origin-only Protect result would
clear the stored address, and an origin-only Axis result would drop its media
path (`/axis-media/media.amp`, which is not a secret). The switch belongs to
Core and is visible to the plugin.

Mechanism: a host-owned config key, the same kind as
`_serviceradar_run_overrides` (`go/pkg/agent/plugin_runtime_overrides.go:52`,
read by plugins through the SDK constant `sdk.RunOverridesConfigKey`). From
Stage 3, `AgentConfigGenerator.build_plugin_assignment_config/2` puts
`"_serviceradar_camera_stream_addresses": "omit"` at the top level of `params`
for every plugin assignment whose package manifest declares the
`camera_inventory` credential purpose (Protect and Axis today), replacing any
value already there. That map is built on Core (a gateway only encodes it,
`config_sync_forwarder.ex:101`). It reaches the plugin unchanged through
`params_json` and the Wasm `get_config` host call
(`plugin_runtime_execution.go:194-213`), so the Core release alone decides it
and no agent change is needed. The Stage 2 SDK release adds the constant and a
helper that reports whether the key is set. Adding the key changes those
assignments' config generation once, so their plugin runners restart once at the
Stage 3 upgrade. Manifest `capabilities` do not fit:
they list host functions the plugin may call (`unifi-protect/plugin.yaml:8-16`),
the opposite direction.

A Stage 2 plugin that sees the key with value `omit` reports `source_origin` per
profile in inventory results, and no `source_url`, `source_url_override`,
`streams[].url`, raw `cameras[].channels` or alias key. Without the key it
reports them exactly as today. After Stage 3, D2 drops any address that an
older plugin still sends.

Shipping Stages 2 and 3 in one release remains allowed and makes the key a
no-op for the transition; it is not required.

Rejected alternative: have Core ignore a missing address and keep the stored
one. That would also keep a stale address for a camera that genuinely lost its
stream.

## Stages (landing order)

1. **Containment** (Core and web-ng; about 1 PR, medium-small). D4 attribute
   hiding and readers moved to `source_scheme`. D2 applied at plugin-result
   entry under its Stage 1 ingest rule: everything persisted or passed on comes
   from the reduced result, and only `put_relay_addresses/2` writes the two
   columns, from the relay address extract. Device metadata
   `camera_source_url` and the profile alias keys are no longer written. D7
   runs its Stage 1 targets. **This leaves the address at rest in
   `source_url` and `source_url_override`. It is not the fix.**
2. **Edge resolution** (SDK, Protect and Axis plugins, agent; 2 to 3 PRs plus an
   SDK release, medium). The resolver contract, plugin resolvers, the D8 key in
   the SDK and its handling in both plugins, agent resolver invocation, the
   `camera_source_resolution` capability, and the new failure classes.
   Inventory results do not change in this stage: no Core sends the D8 key
   before Stage 3, so the plugins keep reporting addresses.
3. **Core cutover** (Core and web-ng; 1 PR, medium; same release as Stage 2 or
   later). The `source_resolver` payload, removal of the two attributes,
   deletion of the D2 Stage 1 ingest rule (`RelayAddressExtract` and
   `put_relay_addresses/2`), the D8 key in plugin assignment config,
   `source_origin` and `discovery_assignment_id`, and D7 runs again with its
   Stage 3 targets in scope.
4. **Contract** (next release; small). Drop the columns and their D7 targets,
   remove the agent's legacy `source_url` branch, refresh the baseline schema.

## Risks / Trade-offs

- Streams pause on agents that are not upgraded. The reason is clear and the fix
  is to upgrade the agent. Mitigation: release notes, and the classified reason
  shown on the camera page.
- Opening a stream adds one controller round trip. This is acceptable for
  user-initiated and recording opens.
- A recursive walk runs on every plugin result. It is bounded by result size and
  the D2 nesting depth, and skips strings that contain neither `:` nor a
  backslash and do not start with `{`, `[` or `"`.

## Open Questions

- Product owner: is the hard cut in D6 acceptable? The alternative is to keep
  sending the stored address to agents that are not upgraded, which keeps the
  secret at rest until the last camera agent upgrades. Decided: hard cut.
- Product owner: is the Stage 1 to Stage 3 rolling-deploy window in D6
  acceptable? Recommendation: accept the interruption. Relay opens served by
  not-yet-upgraded Core nodes can fail for the duration of the rollout, no
  address is written, and it clears when the rollout completes. The alternative,
  delivering the D8 key only once every connected Core node reports Stage 3
  (the D7 `:erpc` stage check), adds a cluster-wide check to the config-compile
  path for a window of minutes per upgrade.
