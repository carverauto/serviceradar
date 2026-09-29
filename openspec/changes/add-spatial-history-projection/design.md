## Context

Consume the negotiated contract from `add-spatial-observation-ingestion`.
This change owns persistence, replay and reads, not a new plugin ABI.

## Storage and reads

### One history writer and bounded current state

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
`add-spatial-observation-ingestion`; do not pick an arbitrary producer because it arrived last. An uncertain
or stale position is visible as such. Consumer replay is not a new live movement.

### Authorized read APIs

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
`add-shared-spatial-resources` owns URL updates, multi-map addressing and authorization.

## Migration and limits

Ship behind a negotiated capability. Preserve existing scalar metric, inventory,
camera and topology contracts. Add Ash resources/generated migrations for control
state and versioned telemetry schema changes for both supported backends. Do not
convert every device into a new object record or replay live data as fixtures.
The drone simulator can adopt atomic positions; its battery/SNMP measurements stay
metrics. A fixed-object, non-network example proves the same resource interface.

## Delivery and isolation

Use treehouse and remote RBE with --config=remote; no Docker, local compilation
or new shell scripts. Automated database tests use srql-fixtures scratch DB only.
All fixtures are independently invented. Use migrations for schema changes.
Run required checks and make test before a PR; deliver every PR through no-mistakes.
