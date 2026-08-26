# Task 4b report: live Radial overview geometry

## Result

The live failure had two causes, both at the overview boundary rather than in the
database or ELK bootstrap:

1. Overview projection promoted any node with a non-attachment incident relation or
   `topology_plane=backbone`. In the captured 194-node / 374-edge snapshot, that
   admitted ordinary endpoints, virtual guests, unknown sightings, and mapper-only
   observations as infrastructure. The browser failure contained 182 glyphs, 181 tree
   routes, and one cross-link instead of a bounded transport overview.
2. After projection was bounded, ELK Radial's default initial ring was still too tight
   for the three-component, high-fanout live transport forest. Two semantic envelopes
   overlapped and tree chords intersected nonincident envelopes.

The fix mirrors the server's endpoint-like classification in the projection, then asks
ELK Radial for deterministic bounded radii while leaving the strict geometry validator
unchanged.

## Design

### Bounded semantic projection

- Infrastructure membership is now identity-based. The client transport allowlist is
  `router`, `switch`, `hub`, `firewall`, `load_balancer`, `access_point`, `ap`, `ids`,
  `ips`, and `endpoint_cluster`, matching the server boundary.
- `endpoint-anchor` remains explicit infrastructure and `endpoint-summary` remains a
  collapsed summary. Ordinary endpoints are omitted from the overview.
- `endpoint_attachment_projection` and `mapper_topology_sighting` identity sources
  cannot be promoted merely because an inferred relation names them.
- Hosted relations do not become transport. Candidate forest pairs must carry a real
  transport relation and both endpoints must already have transport identity.
- Node type resolution uses decoded `details.cluster_kind`, then `details.type`, then
  the raw `kind` fallback. The regression fixtures deliberately omit raw `kind` so they
  exercise the browser's decoded shape.
- The deterministic union-find forest, root ordering, semantic relation identities,
  evidence metadata, and metadata-only cross-links are unchanged.

### ELK-only radial geometry

- ELK Radial remains the sole coordinate authority. There is no post-layout node
  displacement, collision shim, alternate layout algorithm, or route rewrite.
- Each ELK request uses the ID sorter, `NODE_SIZE` wedge criterion, no radial
  compaction, and an initial radius derived from the semantic envelope: 224 pixels
  (`2 * 112`). Disabling compaction prevents ELK from collapsing the requested ring
  separation back into the invalid dense result.
- If strict validation rejects an ELK result, layout retries only the declared initial
  radius, deterministically and at most three times: 224, 448, and 896 pixels.
- Every successfully decoded attempt is passed through the existing overlap,
  nonincident-node intersection, route crossing, route overlap, identity, and bounds
  checks. Coincident finite semantic centers use a private retryable geometry error so
  the next radius can repair them; malformed IDs, endpoints, dimensions, and other
  structural decode errors still fail immediately. Exhausting the bounded attempts
  still throws `invalid radial topology overview`; no validator check was removed or
  downgraded.

The ELK option choices were checked against the official Radial algorithm and option
references:

- <https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-radial.html>
- <https://eclipse.dev/elk/reference/options/org-eclipse-elk-radial-radius.html>
- <https://eclipse.dev/elk/reference/options/org-eclipse-elk-radial-sorter.html>
- <https://eclipse.dev/elk/reference/options/org-eclipse-elk-radial-compactor.html>

## TDD evidence

The high-cardinality projection regression was added first. With the previous
projection it admitted 165 semantic nodes rather than the hand-derived three-node
transport backbone; the paired real-ELK test reported 162 endpoint glyphs instead of
omitting them.

```text
projection: expected [access, core, handoff], received 165 node IDs
radial manifest: expected glyphs=2/treeRelations=1/omittedAttachmentNodes=160,
received glyphs=162/treeRelations=161/omittedAttachmentNodes=0
```

After the allowlist change, the mapper sighting still leaked because it advertised
`type=Router`. A second RED isolated identity source as the remaining promotion path;
the explicit non-promotable source check made it GREEN without excluding the direct
Firewall handoff.

An anonymized 20-node / 17-semantic-route fixture preserving the exact live component
shape was then run through real `elkjs`. Before the Radial option change it failed with
the same class of errors as production:

```text
invalid radial topology overview:
semantic nodes node-02 and node-05 overlap;
semantic nodes node-13 and node-17 overlap;
route relation-02 has coincident points;
route relation-08 intersects nonincident node node-05
```

The radius strategy made that real-ELK regression GREEN. Separate tests prove that an
invalid first result advances to radius 448 and that three invalid results attempt
exactly 224/448/896 before failing closed.

Review then found that coincident semantic centers threw during route decoding before
the retry loop could advance. The regression was added first and failed after only the
224 attempt:

```text
layout_elk_radial_overview > retries coincident semantic centers ... FAILED
relation alpha-beta has coincident semantic geometry
```

A private retryable geometry error now distinguishes that finite, radius-remediable
case from malformed ELK output. The same regression is GREEN and observes attempts
`["224", "448"]`; unknown IDs, bad endpoint bindings, missing coordinates, and invalid
dimensions remain fail-fast decoder errors.

The stricter projection exposed one legacy Arrow identity fixture whose two nodes had
no type at all. That fixture went RED because endpoint-like untyped nodes correctly no
longer produce overview geometry. Adding `Router` and `Switch` to its two synthetic
`node_details` rows restored the fixture's intended transport-edge identity test without
changing production classification.

Focused GREEN:

```text
./node_modules/.bin/vitest run \
  js/lib/god_view/topology_overview_projection.test.js \
  js/lib/god_view/layout_elk_radial_overview.test.js

Test Files  2 passed (2)
Tests       23 passed (23)
```

Affected Arrow integration GREEN:

```text
./node_modules/.bin/vitest run \
  js/lib/god_view/lifecycle_stream_decode_identity.test.js --maxWorkers=1

Test Files  1 passed (1)
Tests       3 passed (3)
```

## Live diagnostic evidence

The raw live snapshot stayed in `/tmp` and is not a committed fixture. A temporary
diagnostic harness parsed `details_json` the same way as the browser before invoking
the production projection, real bundled ELK, decoder, and validator.

Post-fix result for the captured 194-node / 374-edge snapshot:

```text
semantic glyphs:       20
semantic tree routes:  17
components:             3
cross-links:            0
ELK-only super-root:     1 node / 3 joins (not rendered)
initial radius:        224
layout + decode:       226.89 ms
validation:            ok (0 errors)
bounds:                -384.27,-384.27 -> 1443.14,1443.14
```

The first bounded radius passed, so the live graph incurs no retry. Earlier option
probes against the same snapshot showed radius 192 still overlapping while 208 and 224
validated; 224 provides a deterministic envelope-derived margin rather than encoding a
snapshot-specific threshold.

## Final verification

```text
bun run lint:god_view
# exit 0

bun run typecheck:god_view
# exit 0

bun run test:god_view:contracts
Test Files  7 passed (7)
Tests       12 passed (12)

./node_modules/.bin/vitest run god_view_*test.js \
  js/lib/god_view/*.test.js --maxWorkers=1 --testTimeout=15000
Test Files  49 passed (49)
Tests       486 passed (486)

bazel test -c opt --config=remote \
  //elixir/web-ng/assets:god_view_scene_tests
//elixir/web-ng/assets:god_view_scene_tests PASSED in 5.5s
Executed 1 out of 1 test: 1 test passes.
```

The direct full suite uses a 15-second per-test ceiling because several real-ELK
integration cases exceed Vitest's five-second default under concurrent workstation
load. Every test passed serially, and the canonical Bazel target passed the complete
God View suite remotely.

## Files

- `elixir/web-ng/assets/js/lib/god_view/topology_overview_projection.js`
- `elixir/web-ng/assets/js/lib/god_view/topology_overview_projection.test.js`
- `elixir/web-ng/assets/js/lib/god_view/layout_elk_radial_overview.js`
- `elixir/web-ng/assets/js/lib/god_view/layout_elk_radial_overview.test.js`
- `elixir/web-ng/assets/js/lib/god_view/lifecycle_stream_decode_identity.test.js`
- `.superpowers/sdd/2026-08-24-topology-radial-atlas/task-4b-report.md`

## Self-review and concerns

- The live raw snapshot was used only for local diagnosis; no production identifiers,
  labels, addresses, or topology rows were copied into the repository. The committed
  crowded-forest fixture uses anonymous sequential IDs and only the structural shape.
- A realistic mutation that restores incidental-edge promotion fails the 160-endpoint
  regression. Removing the mapper-source exclusion leaks the sighting. Removing the
  first valid radius or bounded retry behavior fails the real-ELK/options or retry
  regressions. Returning invalid geometry after the last attempt fails the fail-closed
  test.
- The projection intentionally omits server/host/virtual/unknown observations from the
  overview because the server treats kinds outside the transport allowlist as
  endpoint-like. They remain available through endpoint summaries and bounded detail;
  this is semantic coarsening, not client-side sampling.
- Radius retries are bounded, deterministic, and validation-driven. A future topology
  that remains invalid at radius 896 will still surface an actionable layout failure
  rather than render overlapping or intersecting geometry.
