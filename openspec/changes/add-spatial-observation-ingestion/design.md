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

## Wire and admission decisions

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
Full wire schema, numeric bounds and SDK cross-language vectors are frozen by this proposal before persistence work begins.

## Ownership

Persistence, current-position projection and provider reads are owned by
`add-spatial-history-projection`; shared navigation is owned by
`add-shared-spatial-resources`. Freeze producer-handoff, equal-time conflict and
future-clock semantics here before either backend implements them. Preserve
provenance without adding SCRITH ontology or causal features.

## Delivery and isolation

Use treehouse and remote RBE with --config=remote; no Docker, local compilation
or new shell scripts. Automated database tests use srql-fixtures scratch DB only.
All fixtures are independently invented. Use migrations for schema changes.
Run required checks and make test before a PR; deliver every PR through no-mistakes.
