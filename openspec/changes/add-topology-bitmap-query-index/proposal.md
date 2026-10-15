# Change: Add a topology bitmap query index

## Why

The topology renderer currently builds Roaring state sets over temporary node
positions but sends only their sizes and counts. Filtering still scans the
loaded node arrays. The tiled renderer also has a separate Arrow path; adding
bitmap bytes only to the legacy snapshot would leave the active product path
unchanged. [Issue #5656](https://github.com/carverauto/serviceradar/issues/5656)
requests a real fleet query index with bounded browser delivery.

The prerequisite renderer/layout repair is separate. This change preserves the
automatic ELK rebuild on trusted parent-tree changes and the GPU resource
lifetime fix. Filtering must not move devices or rebuild layout.

## What Changes

- Reuse the persisted device ordinal dictionary, preserving existing assignments
  and merge tombstones. Widen its signed integer storage to a checked unsigned
  32-bit range; allocate missing IDs in bounded work. Canonical endpoint devices
  share this dictionary. Interfaces use an explicitly separate typed dictionary.
- Maintain incremental Rust Roaring indexes for supported inventory attributes,
  current availability, and separately sourced causal/alert/impact membership.
- Evaluate AND, OR and ANDNOT queries, exact facets, bounded pages and aggregate
  match counts on the server. Intersect current authorized visibility from the
  first release, including cache hits, counts, detail reads and stream updates.
- Deliver actual portable Roaring bytes and revisioned XOR updates for the
  admitted view. Use roaring-wasm for membership and derive only bounded render
  masks. Arrow remains the attribute/geometry transport.
- Add bounded dirty-work admission, reconciliation, cache accounting and explicit
  resynchronization. No full-fleet bitmap or UID dictionary is downloaded to a
  browser to answer a viewport question.
- Benchmark synthetic 100,000 infrastructure devices plus 1,000,000 endpoint
  devices against the current array approach, including realistic sparse IDs,
  churn, fanout, permissions and allocation/copy measurements.

## Scope and Decisions

This PR is a proposal, not an implementation or a claim that scale targets have
passed. Implementation starts after proposal approval and is split into the
three phases in `tasks.md`.

The deployment remains single-deployment. The issue's tenant/customer language
does not introduce tenancy, routing or authorization bypasses. Existing RBAC
and effective device visibility define the authorized set. Permission checks
are not deferred to the issue's suggested fourth phase.

The first protocol uses portable 32-bit Roaring. Exhaustion fails explicitly;
64-bit identifiers require a separately versioned migration and browser codec
proof, not an automatic switch to an incompatible serializer.

## Impact

- Capability: additive requirements under `topology-god-view`.
- Persistence: existing `platform.device_fleet_ordinals`, an interface identity
  dictionary, and bounded durable dirty-work tracking through Ash resources and
  generated migrations. No telemetry storage changes.
- Server: inventory identity writers, topology world/health owner, Rust NIF,
  tile/query/detail controllers and authenticated stream.
- Browser: topology transport, Roaring WASM membership, tile-local typed masks.
- Validation: native set algebra, database identity/convergence, authorization,
  binary interoperability, browser lifecycle and remote scale benchmarks.
- Related changes: `add-endpoint-sbom-inventory`,
  `refactor-topology-read-model-for-carrier-scale`,
  `adopt-god-view-columnar-webgpu`, and `verify-topology-feature-parity`.
  Existing snapshot requirements and archived specifications are not rewritten.

## Review Artifacts

- [Design](design.md), [requirements](specs/topology-god-view/spec.md),
  [implementation tasks](tasks.md).
- [Architecture](../../../docs/architecture/topology-bitmap-index.html) and
  [portable proposal review](../../../docs/architecture/topology-bitmap-index-proposal.html).
- [Arrow path audit](../../../docs/topology-binary-path-audit.md).
