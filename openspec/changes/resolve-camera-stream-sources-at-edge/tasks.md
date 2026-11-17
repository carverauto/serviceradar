## 1. Containment (Stage 1; Core and web-ng only)

- [x] 1.0a Verify that the installed Ash version supports `select_by_default? false` on an
      attribute. If it does not, 1.1 must instead remove the two attributes from every read
      action's default select explicitly.
- [x] 1.0b Verify how a `service_status` row stored before Stage 1 behaves when the same plugin
      result is redelivered after D7 reduced its details and recomputed its payload digest: no
      duplicate row and no resurrection of the unreduced payload. If either occurs, the D2
      digest and the D7 scrub must be changed so a redelivery matches the reduced row before
      1.3 and 1.5 land.
- [x] 1.1 `Source.source_url` and `StreamProfile.source_url_override`: `public? false`,
      `sensitive? true`, `select_by_default? false`; `RelaySourceResolver` selects them
      explicitly (D4).
- [x] 1.2 Add the `source_scheme` calculation; switch the device camera panel and the God View
      payload and JS to it; drop `source_url` and full profile structs from device assigns.
- [x] 1.3 Add `ServiceRadar.Camera.StreamAddressReduction` (D2) and apply it at both
      `PluginResultIngestor` entry points under the D2 Stage 1 ingest rule: build every
      persisted and passed-on value from the reduced result; add `RelayAddressExtract` and
      `InventoryIngestor.put_relay_addresses/2` as the only source and setter of the two
      columns; digest the reduced payload.
- [x] 1.4 `InventoryIngestor`: stop writing `camera_source_url`; filter profile metadata against
      the allowlist.
- [x] 1.5 `StreamSecretScrubWorker` with the D7 target list and job-stage rule, plus the migration
      that enqueues the stage 1 job; bump `core.migrations.expectedVersion`; run
      `scripts/db/check-migration-startup-safety.sh`.
- [x] 1.6 Tests at the owning boundaries: a reduction unit table; a plugin-result ingest test
      asserting that no stored status, state, device, source or profile row holds an invented
      `rtsps://` path or alias outside `source_url` and `source_url_override`, that those two
      columns hold it, and that a report arriving after a scrub pass that left in-scope
      `pending/0` at zero leaves it at zero (D2 Stage 1 ingest rule; fixtures use
      `192.0.2.0/24` and `example.com`); a scrub worker test covering each condition of the D7
      completion rule: a pass that changed rows snoozes the same job and inserts none, a
      concurrent write to another column of a row does not block that row's scrub, a row whose
      scrubbed column changed since it was read is skipped and the job snoozes, a pass that
      changed and skipped nothing snoozes while `pending/0` is non-zero for a job target, the
      max-passes error, a target held while an older or unresponsive node is connected, and a
      stage 3 job run by stage 1 code snoozed and not completed; and a
      web-ng test asserting that assigns hold no address.
- [x] 1.7 `StreamSecretScrubWorker.pending/0` (D7) and a test that feeds invented rows through
      it and through the worker's scrub of the same in-scope target and asserts they agree: an
      origin only (not pending); `rtsps://` with a path; `rtsp://` with userinfo; `https://`
      with userinfo; an alias key in profile, source and device metadata; a path and a
      userinfo written with JSON solidus escapes (`\/`, `\u002f`, `\u0040`); a URL and an
      alias key inside a double-encoded JSON string; and a value nested beyond the D2 depth
      (each pending, and clean after one pass, the last replaced by the D2 marker). The same
      test asserts that a path left in `source_url_override` or `source_url` appears only in
      `at_rest_until_stage_3` and does not block completion.

## 2. Edge resolution (Stage 2)

- [x] 2.0 Verify that the agent's on-demand plugin call for an assignment
      (`RunPluginVerbForAssignment`) receives the same params and standing credential broker
      grants as a scheduled run of that assignment. If it does not, the resolver cannot
      authenticate, and Stage 2 must add that first.
      Result: it does not. The call runs the config its caller supplies and never reads the
      assignment's params. A scheduled run holds no broker grant either: Core writes the
      resolved credential into the params. `ResolveCameraSource` therefore passes the
      assignment's params plus the request key (D1 step 2).
- [x] 2.1 `serviceradar-sdk-go`: request and response types and a helper for
      `serviceradar.camera_source_resolution{_request}.v1`, and the D8 config key constant with
      a helper that reports whether it is set; release, then re-vendor in both plugins.
      Released as SDK v2.3.0; the plugins vendor v2.3.1, which reads a null
      `_serviceradar_camera_stream_addresses` as an error (omit). Only the two camera plugins
      (Protect, Axis) were re-vendored.
- [x] 2.2 Protect plugin: a resolver for one camera (integration `rtsps-stream` first, bootstrap
      second), never creating streams; inventory results as D8 states (unchanged without the
      key; with it, `source_origin` and no `cameras[].channels` aliases, `streams[].url` or
      `source_url*`).
- [x] 2.3 Axis plugin: a resolver that rebuilds the URL with the plugin credentials as its
      userinfo; inventory results as D8 states.
- [x] 2.4 Agent: a `source_resolver` payload field; invoke the assignment on demand with its
      params (task 2.0); capture the resolved URL in memory and pass it to the native reader as `SourceURL`, never
      persist it or enqueue it as a result;
      advertise `camera_source_resolution`; add the D5 classes; confirm that no log line,
      command result or error carries the resolved URL or its userinfo.
- [ ] 2.5 Tests: plugin resolver tables against fake controllers; plugin inventory tables with
      and without the D8 key (without it, the descriptor address fields match the current
      output); an agent test showing the address reaches the reader and nothing else, and that
      each D5 class is produced.
      Plugin half done: `protect_source_resolution_test.go` and `axis_source_resolution_test.go`
      run `run_check` against fake controllers through the SDK local host.

## 3. Core cutover (Stage 3)

- [ ] 3.1 Remove both attributes from the resources; add `source_origin` and
      `discovery_assignment_id` (migration); the ingestor records provenance `assignment_id`.
- [ ] 3.2 `RelaySourceResolver` builds `source_resolver`; the capability gate produces
      `agent_upgrade_required`; `source_resolver_missing`.
- [ ] 3.3 Delete the D2 Stage 1 ingest rule (`RelayAddressExtract`,
      `InventoryIngestor.put_relay_addresses/2`) so D2 applies alone; set `source_origin` as D2
      states.
- [ ] 3.3a `AgentConfigGenerator.build_plugin_assignment_config/2` delivers the D8 key to
      `camera_inventory` assignments; tests for the three cutover combinations in the
      camera-streaming spec delta.
- [ ] 3.4 A migration enqueues the D7 stage 3 scrub job (a new job, not the stage 1 job); bump
      `expectedVersion`; extend the 1.7 test with a path in `source_url_override`, a verbatim
      URL in `source_origin` and a non-null `source_url` (each pending, clean after one pass),
      and assert `at_rest_until_stage_3` is absent; add a scrub worker test for the
      camera-streaming scenario of a concurrent inventory upsert during a stage 3 pass.
- [ ] 3.5 Web-ng operator sentences for the D5 classes.
- [ ] 3.6 DB-backed tests in the Core Integration lanes; every unboxed test deletes its rows.

## 4. Contract (Stage 4, next release)

- [ ] 4.1 Migration that drops `camera_sources.source_url` and
      `camera_stream_profiles.source_url_override` and removes D7 targets 5 and 7; refresh the
      baseline.
- [ ] 4.2 Remove the agent's legacy `source_url` branch.

## 5. Docs

- [ ] 5.1 `docs/docs/unifi-protect.md`: streams resolve on the agent; upgrade order (the D6
      release-ordering rules); regenerate aliases after upgrading. The upgrade notes state
      that during the Core upgrade that performs the cutover, relay opens served by
      not-yet-upgraded Core nodes can fail until the rollout completes (D6).
- [ ] 5.2 `docs/docs/srql-language-reference.md` `camera_sources` paragraph.
- [ ] 5.3 Runbook under `docs/`: the `pending/0` verification command defined in design D7, the
      DLQ purge, backup expiry.
