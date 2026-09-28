## Context

The current Go/Rust SDKs expose telemetry emission, device discovery and camera
descriptors. `go/pkg/agent/plugin_runtime_telemetry.go` validates bounded telemetry
batches; `PluginResultIngestor` explicitly rejects result-payload metrics as a
storage path. `EventWriter.Processors.Metrics` owns canonical metric decoding.
`add-showcase-demo-portfolio` D5 currently models motion as scalar metrics and D10
proposes plugin topology links. This proposal supplies a coherent position record
for moving objects and keeps numeric measurements on the existing metric path.

FieldSurvey already has spatial resources and artifact metadata. Its artifact
store is not a generic high-rate motion writer. The million-device topology world
is an authored Cartesian layout, not a geographic projection; its persisted
coordinates and tile generations stay owned by the topology provider.

## Goals / Non-Goals

- Goals: one position has one timestamp and identity; the same map APIs serve
  fixed and moving objects; replay cannot move current state backward; storage
  policy stays in the platform; unrelated domains can adopt the same contract.
- Non-goals: a universal ontology, SCRITH reasoning, arbitrary plugin SQL/DQL,
  storing video in telemetry tables, or replacing existing topology/FieldSurvey
  layouts with a geographic coordinate model.

## Decisions

### 1. Plugins describe records; the platform routes and authorizes them

Extend the existing telemetry host interface with a negotiated, versioned spatial
payload. Do not create a second transport or a plugin-supplied destination field.
Register it through the edge output-contract machinery as that machinery lands;
do not independently change its frozen record ABI. SDK and host must agree before
the capability is advertised. Unknown versions are rejected explicitly.

Each record carries a stable object reference, source observation ID, event time,
and one complete position. The trusted host supplies assignment/producer identity
and observed/received time. A reference identifies a provider-owned object inside
an authorized spatial resource, not a tenant. Existing device IDs can be linked;
objects such as markers, equipment, vehicles or observations need not be devices.

The coordinate descriptor declares geographic WGS84 longitude/latitude or an
explicit Cartesian space with version, units, axes and origin. Optional altitude
includes its vertical datum; heading, velocity and accuracy include units and
quality. Missing or uncertain values remain missing/uncertain. A geographic point
never acquires invented Cartesian coordinates merely to fit a topology tile.
Full wire schema, numeric bounds and SDK cross-language vectors are task 1.1.

### 2. One history writer; bounded derived current state

| Data | Owning storage/path |
| --- | --- |
| Resource definitions, fixed geometry, geofences, credentials and permissions | CNPG/Ash; PostGIS for geographic geometry and spatial predicates |
| Position history, scalar metrics, detection/event history | JetStream -> EventWriter -> StarRocks when enabled; otherwise CNPG telemetry backend |
| Current position | Bounded CNPG/PostGIS projection from accepted observations; source record ID, event time and freshness retained |
| Canonical relationships | Existing canonical ingestion -> Dgraph projection; bounded relation changes, not one edge per position sample |
| Video, recordings and large artifacts | Object storage; authorized metadata/reference APIs (recording design is separate) |
| Map geometry and tiles | Provider-owned persisted geometry/index/cache; topology world remains its own Cartesian provider |

The current-position projection is a replaceable latest-state index, not a second
append-only telemetry archive. It has an independent durable consumer/checkpoint,
idempotency and rebuild path; history acknowledgement never implies all projections
are current. Readers expose projection lag. A warehouse outage is retried on
JetStream, never silently redirected into CNPG history.

Select current state by event time within an authorized producer epoch/sequence.
Duplicates do not create duplicate history or effects. Late observations remain
in history but do not replace newer state. Equal-time conflicts, producer handoff,
clock skew and future timestamps have explicit admission/winner rules frozen in
task 1.1; do not pick an arbitrary producer because it arrived last. An uncertain
or stale position is visible as such. Consumer replay is not a new live movement.

### 3. Read APIs compose data without exposing store topology

The host's authorized resource descriptor owns bounds, coordinate space, Home
camera, supported layers and identity resolution. A bounded viewport query or
tile fetch supplies geometry; a bounded dynamic overlay supplies current positions
and status. History queries are separately time/row bounded through SRQL or the
authorized provider API. Dynamic updates invalidate overlay state, not every static
tile. Each response names its revision/time and lag; there is no fictional atomic
snapshot across CNPG, Dgraph and StarRocks.

Share URLs identify dashboard/map resource, coordinate-space version, center and
zoom (longitude/latitude for geographic views). An optional object identity resolves
the object's current location on open; a fixed-camera link preserves its location.
An explicit historical time is a separate mode, not implied by sharing an object.
The existing D19 contract owns URL updates, multi-map addressing and authorization.

### 4. Shared evidence for future SCRITH

Preserve stable identities, source provenance, event/receive timestamps, schema
versions and replayable observations. SCRITH can later consume authorized streams
and references through an explicit integration. This work supplies neither an
ontology language nor a causal engine, and creates no speculative schema for them.

## Migration Plan

Ship behind a negotiated capability. Preserve existing scalar metric, inventory,
camera and topology contracts. Add Ash resources/generated migrations for control
state and versioned telemetry schema changes for both supported backends. Do not
convert every device into a new object record or replay live data as fixtures.
The drone simulator can adopt atomic positions; its battery/SNMP measurements stay
metrics. A fixed-object, non-network example proves the same resource interface.

## Risks / Trade-offs

- High-rate motion can overwhelm current-state writes: bounded/coalesced projection
  with measured lag and preserved full history, never unbounded write-per-frame.
- Cross-store lag is observable: responses expose watermarks/freshness; no silent
  join against frozen CNPG telemetry when StarRocks is enabled.
- Layout migration changes coordinate meaning: versioned spaces and explicit
  unavailable-location behavior, not guessed coordinates.
- Separate latitude/longitude histories may disagree: migrate producers to atomic
  positions; do not synthesize a trustworthy point from unmatched samples.

## Open Questions

- Freeze maximum sample rate/batch bytes and supported current-state lag from
  synthetic benchmarks before enabling the capability by default.
- Decide the initial history-query shapes and producer-handoff tie-breaking rule
  during schema review; both are explicit release gates in tasks 1.1 and 3.1.
