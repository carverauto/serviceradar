# Tasks: add-plugin-driven-prefix-tag-sources

> Do not implement until this proposal is approved and
> `add-flow-prefix-tag-enrichment` has merged.

## 1. Spec & catalog contract

- [ ] 1.1 Extend `IntegrationDescriptor` validation with bounded
      `prefix_tag_sources` entries (source id, label, description, schedule
      binding, optional limits)
- [ ] 1.2 Load `prefix_tag_sources` into `IntegrationCatalog` with
      duplicate-source rejection across packages
- [ ] 1.3 Document claim shape in plugin author docs / sdk notes
- [ ] 1.4 Unit tests: valid descriptor, unknown keys, duplicate sources,
      schedule binding required when declared

## 2. Generic promote / ingest API

- [ ] 2.1 Define `serviceradar.prefix_tag_snapshot.v1` payload schema
- [ ] 2.2 Implement core ingest (validate → building snapshot → bulk insert →
      atomic promote → PubSub invalidate) reusable by plugins and platform
      materializers
- [ ] 2.3 Fail-open / fail-fast parity: never promote partial imports; keep
      previous active snapshot on error
- [ ] 2.4 Telemetry: import outcome, duration, record_count, source
- [ ] 2.5 Tests with fixture payloads (happy path, count mismatch, unauthorized
      source id)

## 3. Decouple scheduling from product modules

- [ ] 3.1 Introduce platform source registry (provider, ti, dns-policy, oui, …)
      without NetBox-named entries
- [ ] 3.2 Remove `NetboxImportWorker` from
      `NetflowEnrichmentDatasetScheduler`
- [ ] 3.3 Ensure plugin-claimed prefix-tag sources are scheduled via
      producer schedules / assignment (mirror inventory contract)
- [ ] 3.4 Scheduler tests: no hard dependency on NetBox module

## 4. IntegrationSource & UI de-hardcoding

- [ ] 4.1 Plan migration off closed `source_type` atom list for product
      integrations (catalog string ids)
- [ ] 4.2 Integrations LiveView: options from catalog, not fixed Netbox/Armis
      HEEx lists (Armis may remain transitional)
- [ ] 4.3 Prefix Tags LiveView: tabs from active snapshots + catalog labels
- [ ] 4.4 RBAC unchanged (`settings.prefix_tags.manage`, integrations manage)

## 5. NetBox as a standalone plugin

- [ ] 5.1 Implement / extend NetBox Wasm plugin: credentials, HTTP pagination,
      map to `prefix_tag_snapshot.v1`, declare `prefix_tag_sources`
- [ ] 5.2 Package docs, config schema, allowlists, recommended cadence
- [ ] 5.3 Dual-path or flag cutover from core `NetboxImportWorker`
- [ ] 5.4 Delete `PrefixTags.NetboxImportWorker` and product-specific tests
      from core
- [ ] 5.5 Update `docs/docs/netbox.md` and `docs/docs/prefix-tags.md` for
      plugin ownership

## 6. Validation & ship

- [ ] 6.1 `openspec validate add-plugin-driven-prefix-tag-sources --strict`
- [ ] 6.2 Core + web-ng compile; focused catalog/ingest/scheduler tests
- [ ] 6.3 Demo or staging: approve NetBox package, assign, verify snapshot
      promote and flow tags without core worker
- [ ] 6.4 Release notes: operator migration if worker removal is **BREAKING**
