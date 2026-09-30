# Topology parity audit

Scope: #4908, the tile world and bounded ELK scenes in #4774/#4901.
This is an implementation audit, not a completed hardware/product acceptance report.

| Behavior | Current implementation | Evidence and remaining work |
| --- | --- | --- |
| World Home and pan/zoom | Persisted 2^24 world; Home fits active-device bounds, with a legacy extent fallback; bounded tile LOD | Existing million-browser check totals 1M and exercises pan/zoom/cache. Real product million-data proof remains #4909. |
| ELK layout | Explicit neighborhood/member scenes use `GodViewRenderer.mountScene`, schema 3 and `elk-scene-detail` | Existing WebGPU tests open ELK scenes at DPR 1/2. Test real product scenes, paging and resize on hardware. The background worker now composes bounded executions of the pinned ELK radial engine into persisted world positions; the tile browser retains its bounded delivery path. Native connected 1M/2M geometry passes. Authenticated product and hardware acceptance remain pending. |
| Control ownership | World owns global subscriptions; active detail needs local control delivery | Found missing scene callbacks and retained-world zoom movement. Fixed with scene-local callbacks and retained map-camera ownership. Remote browser regression passed. |
| Traffic toggle | Existing renderer forced atmosphere back on in every render | Removed forced enable; passing browser checks visible packet layers off/on and saved settings on cached reopen. |
| Detail traffic | `WorldScene.encode` writes zero edge counters; detail scenes have no live overlay refresh | FAIL: add bounded, revision-fenced scene telemetry using persisted interface bindings. Do not count fixture-only animated detail as product proof. |
| Status and causal filters | World health uses healthy/unavailable/unknown. Existing controls use root_cause/affected/healthy/unknown | GAP: define explicit compatible filter semantics. Availability alone cannot imply causal root/affected status. Detail controls now receive current settings. |
| Topology layers | Detail renderer has backbone/inferred/endpoints/MTR controls. World tiles currently expose aggregate geometry without class filtering | GAP: preserve supported controls or provide an explicit scoped UI; no silently inert buttons. |
| Labels/picking/details | World labels, aggregate counts, typed picking and authorized details; ELK detail retains existing labels/picking | Browser covers world picking and detail entry; hardware neighborhood/attachment usability remains. |
| Search | World exact device-ID search flies to persisted location | Pass in focused browser. Broader hostname/query search remains coordinated with #4449. |
| Paging and return | Cursor-bounded detail pages, four-scene cache, Back to map retains world renderer | Cache/return focused checks exist; exercise next-page and resized detail in product. |
| Links | Compact layout/x/y/z camera links plus device identity links; legacy map_* compatibility | Existing remote million browser covers reload and precision. Links identify world location, not a persisted detail camera. |
| Traffic source | World overlays use SRQL interface rates from SNMP counters; packet families optional | Focused packet/octet tests exist. Full JetStream/EventWriter -> SRQL -> browser evidence remains #4909. |

## Simulation boundary for #4909

Use one million independently invented device identities and at least two million
relations. Native fixture generation and controlled direct topology seeding into
owned isolated storage are allowed. No physical device fleet or WASM plugin is
required. Report separately the numbers in inventory, Dgraph and persisted world
positions, and any normal discovery/ingestion paths bypassed.

The existing persistence benchmark writes 1M world positions and 2M world relations;
it does not prove 1M inventory rows or Dgraph devices. The existing browser fixture
mocks the HTTP/channel telemetry. These are useful distinct checks, not yet the
combined product proof. Synthetic SNMP samples must pass through JetStream and
EventWriter; active telemetry cohort, cadence, offered rate and lag must be stated.

## Verification for control repair

- Before repair: remote browser regression failed twice because the active
  detail zoom did not change. Invocation `f64c02f3-6ed8-481f-8f20-c87ebe251372`.
- After event routing: the same browser test exposed the independent forced
  Traffic enable on redraw. Invocation `1410e98f-2bea-4b93-b020-99a86d524a8a`.
- After both fixes: world WebGPU browser suite and existing scene unit suite
  passed on RBE. Invocation `b630d7fa-235d-4bbb-bfc7-d885800a26b3`.
- These browser checks use invented HTTP/channel fixtures and RBE software
  WebGPU. They do not replace the hardware-GPU/product checks above.
- Full `make test` on RBE: 367 targets passed, 2 Swift targets skipped.
  Invocation `c2471673-8940-467e-bd0f-bd93c4b37070`.

## Maintenance assessment

Ripwire reports three major findings for this increment: mount complexity rose
from 13 to 16, and recent churn on mount and WorldMapRenderer. Eight minor
findings include the larger class and scene-open method. The added branches
route controls to their current owner and retain state across scene lifetimes;
this repair keeps those transitions together instead of introducing another
controller abstraction. No findings were suppressed. This is not a clean
quality-delta verdict; reconsider ownership extraction with the detail-overlay
work, backed by the browser regression added here.
