## 1. Containment (Stage 1; Core and web-ng only)

- [ ] 1.1 `Source.source_url` and `StreamProfile.source_url_override`: `public? false`,
      `sensitive? true`, `select_by_default? false`; `RelaySourceResolver` selects them
      explicitly (D4).
- [ ] 1.2 Add the `source_scheme` calculation; switch the device camera panel and the God View
      payload and JS to it; drop `source_url` and full profile structs from device assigns.
- [ ] 1.3 Add `ServiceRadar.Camera.StreamAddressReduction` (D2) and apply it at both
      `PluginResultIngestor` entry points, exempting only the descriptor fields that feed the two
      columns; digest the reduced payload.
- [ ] 1.4 `InventoryIngestor`: stop writing `camera_source_url`; filter profile metadata against
      the allowlist.
- [ ] 1.5 `StreamSecretScrubWorker` targets 1-4 without the columns, plus the migration that
      enqueues it; bump `core.migrations.expectedVersion`; run
      `scripts/db/check-migration-startup-safety.sh`.
- [ ] 1.6 Tests at the owning boundaries: a reduction unit table; a plugin-result ingest test
      asserting that no stored status, state, device or profile row holds an invented `rtsps://`
      path or alias (fixtures use `192.0.2.0/24` and `example.com`); a scrub worker test covering
      the repeat-until-zero and old-node termination branches; and a web-ng test asserting that
      assigns hold no address.

## 2. Edge resolution (Stage 2)

- [ ] 2.1 `serviceradar-sdk-go`: request and response types and a helper for
      `serviceradar.camera_source_resolution{_request}.v1`; release, then re-vendor in both
      plugins.
- [ ] 2.2 Protect plugin: a resolver for one camera (integration `rtsps-stream` first, bootstrap
      second), never creating streams; results carry `source_origin` and no `cameras[].channels`
      aliases, `streams[].url` or `source_url*`.
- [ ] 2.3 Axis plugin: a resolver that rebuilds the URL and returns plugin credentials; results
      carry the origin only.
- [ ] 2.4 Agent: a `source_resolver` payload field; invoke the assignment on demand with its
      params and standing grants; capture output in memory, never enqueue it as a result;
      advertise `camera_source_resolution`; add the D5 classes; confirm that no log line or
      command result carries the resolved address.
- [ ] 2.5 Tests: plugin resolver tables against fake controllers; an agent test showing the
      address reaches the reader and nothing else, and that each D5 class is produced.

## 3. Core cutover (Stage 3)

- [ ] 3.1 Remove both attributes from the resources; add `source_origin` and
      `discovery_assignment_id` (migration); the ingestor records provenance `assignment_id`.
- [ ] 3.2 `RelaySourceResolver` builds `source_resolver`; the capability gate produces
      `agent_upgrade_required`; `source_resolver_missing`.
- [ ] 3.3 D2 with no exemption; delete the descriptor URL handling in `InventoryIngestor`.
- [ ] 3.4 Enqueue the scrub worker again with the column targets; bump `expectedVersion`.
- [ ] 3.5 Web-ng operator sentences for the D5 classes.
- [ ] 3.6 DB-backed tests in the Core Integration lanes; every unboxed test deletes its rows.

## 4. Contract (Stage 4, next release)

- [ ] 4.1 Migration that drops `camera_sources.source_url` and
      `camera_stream_profiles.source_url_override`; refresh the baseline.
- [ ] 4.2 Remove the agent's legacy `source_url` branch.

## 5. Docs

- [ ] 5.1 `docs/docs/unifi-protect.md`: streams resolve on the agent; upgrade order; regenerate
      aliases after upgrading.
- [ ] 5.2 `docs/docs/srql-language-reference.md` `camera_sources` paragraph.
- [ ] 5.3 Runbook under `docs/`: the D7 verification queries, the DLQ purge, backup expiry.
