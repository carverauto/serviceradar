# Change: Plugin SDKs: typed spatial observations and negotiated host admission

Tracking issue: [#4911](https://github.com/carverauto/serviceradar/issues/4911).

## Why

Define a use-case-neutral atomic spatial observation contract for fixed and moving objects. Drone telemetry is one example, not a required domain model. This is follow-on platform work, outside #4774 completion.

## What Changes

- Stable provider-scoped object identity, observed time and provenance, coordinate reference/version, position and optional motion/quality fields form one atomic observation.
- Specify geographic vs Cartesian coordinates, units/axes, altitude conventions, finite/range validation, size/rate limits, producer handoff, equal-time conflicts and future-clock policy.
- Reuse negotiated edge record/host capability contracts; inspect the producer-neutral work in #4905 before extending the ABI. Unsupported capabilities/versions fail explicitly.
- Add matching Go and Rust builders and host admission with invented cross-language conformance vectors. Coordinate with #4846's general Rust SDK parity work; do not duplicate its existing capabilities.
- Plugins emit semantic records, never choose CNPG/StarRocks tables, S3 buckets or Dgraph predicates. Trusted host context supplies authoritative provenance.

Related workstreams have separate proposals and acceptance checklists.

## Impact

Go/Rust plugin SDKs and negotiated agent-host admission. Coordinates with #4846 and the edge record ABI. Persistence and map rendering are separate changes; this follow-up does not block #4774.

Proposal and tracking only; no deployment, data ingestion or recording is enabled
by this documentation change.
