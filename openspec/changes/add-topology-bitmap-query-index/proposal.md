# Change: Add a topology bitmap query index

## Why

The topology renderer builds Roaring sets over temporary scene positions but
sends only their sizes and counts. The persistent tiled world needs server-side
filtering, exact facets and aggregate match counts without scanning inventory
per interaction or downloading whole-fleet state. [Issue #5656](https://github.com/carverauto/serviceradar/issues/5656)
tracks that requirement.

The renderer/layout repairs and Arrow-path audit are prerequisites. This change
preserves automatic ELK rebuilding on trusted parent-tree changes and the GPU
buffer lifetime fix. Filtering never changes layout.

## What Changes

- Reuse the persisted device ordinal dictionary, preserving assignments and
  tombstones. Widen storage to the checked unsigned 32-bit range and allocate
  missing canonical device IDs in bounded work without burning sequence values
  on repeat reads. Purge allocates tombstoned ordinals for eligible older rows
  that backfill has not reached, preserving identity and merge/seed lineage in
  the same bounded transaction. Canonical endpoints share this dictionary.
- Maintain incremental Rust Roaring indexes for canonical inventory attributes
  and current availability, with bounded publication and explicit freshness.
- Evaluate authorized AND, OR and ANDNOT expressions, exact conjunctive facets,
  live ordinal pages and aggregate match counts on the server. Revalidate current
  authority before delivering counts, details, search or overlays.
- Provide a visible map filter builder for inventory VLAN, supported attributes and
  configured tags, with AND/OR/EXCEPT, text-prefix matching and IPv4/IPv6 CIDR
  membership. CIDR matches any known canonical device or interface address and
  returns devices; it does not introduce interface entity queries.
- Include existing named Prefix Tags as device groups, matching current device
  addresses against their configured networks. Reuse local immutable prefix
  snapshots and their matching-chain semantics, with bounded label discovery.
- Replace the active per-tile JSON overlay with typed binary membership, health
  and flow fields, preserving coverage and unknown-state semantics. Membership
  masks/counts align to admitted Arrow rows. The browser needs neither fleet
  sets nor a Roaring WASM runtime; Arrow remains the geometry transport.
- Use existing bounded invalidation hints and rolling keyset reconciliation.
  Inventory writes do not acquire shared bitmap bucket locks or wait for an
  index replica. Missing hints delay freshness; reconciliation repairs them.
- Benchmark independently synthetic 100,000 infrastructure and 1,000,000 endpoint
  devices, including sparse IDs, sustained churn, authorized fanout and copies.

## Scope and Decisions

The proposal was approved; implementation is in progress. The independent review
in `review.md` led to a smaller scope. The user explicitly chose current
membership on each result page. Every response pins one local revision; a later
page can use a newer revision on any healthy pod. Counts and pages are not a
frozen export. The user also explicitly required usable map filters, text tag
prefixes, IP/CIDR membership across any known device/interface IP, and selection
of existing named Prefix Tags. These are
release-one requirements, not an internal API or an optional follow-up.

The product name for the topology engine and its map is ServiceRadar Atlas,
decided by the user on 2026-10-16. Website, documentation, UI copy and other
public text say "Atlas" or "ServiceRadar Atlas". The `topology-god-view`
capability id, `god_view_*` module and asset names, and the
`SERVICERADAR_GOD_VIEW_ENABLED` flag are unchanged by this change; renaming them
is a separate change.

No cross-pod query ownership, result cache, interface dictionary, durable hint
replication, browser Roaring, XOR history or chunked baseline assembly is added.
These need a demonstrated product requirement before introduction. Causal,
alert/impact, site/role and complete-search facets have no approved fleet source
contract today and remain explicitly unsupported.

The deployment stays single-deployment. Existing RBAC defines visibility from
release one; this work adds no tenancy, routing or authorization bypasses.
Server sets use persistent u32 identities and portable Roaring where sets cross
native boundaries. Exhaustion rejects new allocations; a future 64-bit identity
space requires a separate migration and protocol decision.

## Impact

- Capability: additive requirements under `topology-god-view`.
- Persistence: existing `platform.device_fleet_ordinals`, a durable dictionary
  epoch and retention-safe tombstones. Ash describes the resources; explicit
  SQL owns sequence, trigger and retention invariants that generation cannot
  express. No telemetry storage or durable replication tables are added.
- Server: canonical identity writers, topology lifecycle, Rust NIF, authenticated
  query/detail controllers and bounded tile overlays.
- Browser: binary overlay transport, typed row masks, receipt fencing and GPU
  lifetime handling. No new browser membership runtime dependency.
- Validation: identity transitions, convergence, authorization, binary decoding,
  native scale benchmarks and actual-hardware browser lifecycle checks.
- Related changes: `add-endpoint-sbom-inventory`,
  `refactor-topology-read-model-for-carrier-scale`,
  `adopt-god-view-columnar-webgpu` and `verify-topology-feature-parity`.

## Review Artifacts

- [Design](design.md), [requirements](specs/topology-god-view/spec.md),
  [tasks](tasks.md), [decisions](choices.md) and [review response](review-response.md).
- [Arrow path audit](../../../docs/topology-binary-path-audit.md).
- The [architecture](../../../docs/architecture/topology-bitmap-index.html)
  and [portable proposal](../../../docs/architecture/topology-bitmap-index-proposal.html)
  reflect the reduced binary-overlay design. Keep the new filter-builder and
  named-prefix scope synchronized before delivery.
