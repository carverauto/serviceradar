# Change: Shared spatial observations from plugins to platform maps

## Why

Network topology, fixed sensors, moving vehicles and arbitrary dashboard objects
need a common identity, coordinate and time contract. A latitude metric and a
longitude metric sampled independently cannot safely represent one position.
Plugin authors also need a supported ingestion path without choosing a database.

## What Changes

- Add a versioned, atomic spatial-observation contract and matching Go/Rust SDK
  builders, using the existing host telemetry path and negotiated output contracts.
- Keep durable observations on JetStream first, with EventWriter owning the
  active telemetry backend; derive bounded current-position state in CNPG/PostGIS.
- Define stable resource/object references independent of device identity, while
  allowing explicit links to existing devices and camera sources.
- Provide authorized current-position, history and bounded viewport reads for
  the dashboard spatial-resource contract in `add-showcase-demo-portfolio` D19.
- Reuse canonical relationship ingestion and Dgraph projections; do not put a
  position sample into Dgraph on every update or let plugins choose SQL/DQL sinks.

## Impact

- Affected specs: new `spatial-ingestion`; SDK contracts in the Go and Rust SDK repositories.
- Affected code: plugin host telemetry validation, agent/gateway ingestion,
  EventWriter, spatial Ash resources/migrations, SRQL and dashboard host providers.
- Depends on the applicable `freeze-edge-record-v1-abi` and
  `unify-sweep-results-proto` contract/lifecycle work; does not redefine their ABI.
- Coordinates with `extend-starrocks-to-all-telemetry`,
  `add-showcase-demo-portfolio`, `update-fieldsurvey-spatial-selection`, and
  `add-camera-recording-storage`.
- Proposal only. No deployment change, new database, SDK release or SCRITH
  ontology/causal implementation is included. #4774 remains independently shippable.
