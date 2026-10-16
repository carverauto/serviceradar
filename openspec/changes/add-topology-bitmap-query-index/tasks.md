# ServiceRadar Atlas implementation tasks

## 0. Approved direction

- [x] 0.1 Obtain proposal approval before implementation.
- [x] 0.2 Review implementation complexity and incorporate the user's choice of current membership on each page.

## 1. Persistent identities and bounded server index

- [ ] 1.1 Inventory canonical create/merge/delete/restore and retention writers; preserve the existing device dictionary.
- [ ] 1.2 Widen storage and sequence to checked full-u32, prevent repeat-allocation sequence burn, preserve tombstones and rollback compatibility.
- [ ] 1.3 Add resumable allocation/backfill; verify after-commit hint coverage at real transaction owners.
- [ ] 1.4 Integrate one bounded native publisher with world/health lifecycle, byte-bounded Roaring dirty sets, coherent revisions and rolling keyset reconciliation.
- [ ] 1.5 Implement canonical inventory/availability facets, value and memory caps, explicit readiness and freshness.
- [ ] 1.6 Prove persistence, purge/merge/delete/restore, lost hints, late commits, restart and two-replica convergence.
- [ ] 1.7 Run declared synthetic native benchmarks against an independent array baseline; report actual limits.

## 2. Authorized query and tiled projection

- [ ] 2.1 Validate and normalize bounded expressions; exact AND/OR/ANDNOT and conjunctive facets on one request-local revision.
- [ ] 2.2 Enforce current RBAC on admission and delivery across queries, counts, search, details and overlays.
- [ ] 2.3 Implement authenticated live ordinal cursors usable on any healthy replica, binding query/dictionary/authority.
- [ ] 2.4 Project authorized leaf, aggregate and supported relation/bundle membership to admitted tile rows without relayout or whole-fleet BEAM/browser enumeration.
- [ ] 2.5 Report unsupported causal, site/role, alert/impact and complete-search predicates explicitly; keep availability separate.
- [ ] 2.6 Prove reference parity, empty results, revocation races, bounded details, count isolation and layout independence.
- [ ] 2.7 Add bounded literal value/tag-key prefix predicates and exact IPv4/IPv6 CIDR membership across current canonical device/interface addresses; prove deduplication, source completeness and memory/deadline bounds.
- [ ] 2.8 Reuse local immutable Prefix Tags snapshots for named source/label groups; implement atomic capture, bounded label discovery and native range selection, preserving full-chain semantics and live device pagination.

## 3. Binary admitted-row overlays

- [ ] 3.1 Implement the versioned binary full-replacement envelope and typed state/count columns with fixed allocation limits.
- [ ] 3.2 Prove native-to-browser column interoperability, high canonical IDs, malformed lengths, receipt and state-domain handling.
- [ ] 3.3 Atomically replace matching admitted-row masks; reject stale work and bound slow-viewer coalescing without XOR history.
- [ ] 3.4 Replace the active per-tile health/flow JSON overlay and JSON size checks with bounded binary fields, preserving coverage, unknown values and timestamps; keep Arrow attributes typed.
- [ ] 3.5 Add the default-off rollout gate and explicit unsupported-filter fallback; release masks on eviction/disconnect/disable.
- [ ] 3.6 Run actual-browser zoom/reconnect/GPU-lifetime checks and measure retained bytes and upload copies.
- [ ] 3.7 Deliver a visible filter builder for inventory VLAN/attributes/tags, AND/OR/EXCEPT, text prefix, IP/CIDR and existing named Prefix Tags, with supported-field discovery, pending/error feedback, exact global/aggregate counts and clear-to-base behavior.

## 4. Scale proof and delivery

- [ ] 4.1 Publish latency/memory and admitted-overlay bytes for the synthetic 100k + 1M fixture, including sparse IDs and full-population churn.
- [ ] 4.2 Measure sustained churn, reconciliation DB load, 100 views, high cardinality, replacement headroom and recovery.
- [ ] 4.3 Complete required remote checks and actual-hardware acceptance; identify each unrun check honestly.
- [ ] 4.4 Update README, binary-path audit and native docs to match measured implementation; remove unused experimental paths.
- [ ] 4.5 Refresh architecture/portable review artifacts; publish through no-mistakes. Rollout approval and archival happen separately after shipping.
- [ ] 4.6 Capture the production Atlas map/filter UI before and after the requested expression using only synthetic inventory; add images, figures, hero metadata and show-test coverage to the website blog branch, run `mix precommit` and push with an explicit refspec without opening a website PR.
- [ ] 4.7 Measure WebSocket compression on actual membership frames, including CPU cost and negotiated transport behavior, before deciding whether to enable it.

Deferred: interface identities/queries, durable dirty replication, owner-routed
frozen pages, result caching and browser Roaring. Add them only for a demonstrated
requirement; they are not unfinished release-one implementation tasks.

Follow-up from review pass 3: move SRTO health/flow encoding to native Arrow IPC
to reuse the existing Arrow decoder and nullable columns. Preserve exact tile
receipts, field semantics and bounded cached bytes; compare encoding, decoding,
retained memory and wire size before replacing the current fixed codec. This is
not a release-one blocker. Omission of unchanged tiles also remains measurement
driven; full replacements stay the current protocol.
