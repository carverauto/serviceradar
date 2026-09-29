## Context and decisions

The dashboard SDK's `feat/plan-view` already provides `createPlanView`,
`usePlanView`, `fitPlanBounds` and shared layer factories. Extend those interfaces;
do not embed the God View LiveView hook or make dashboards depend on Dgraph,
SNMP, ELK or the topology schema-3 decoder. Geographic drone maps continue to use
longitude/latitude with the geographic map helper. Indoor plans and logical
networks use explicit Cartesian frames with declared units, axis direction and
bounds. A zoom value is meaningful only with its frame's camera convention.

The platform is use-case neutral: stable objects can be fixed or moving, geographic
or diagrammatic. Drone, infrastructure, vehicle, sensor and process examples do not
become required object classes. Providers own object schemas, motion and presentation;
the shared layer addresses objects by stable, resource-scoped identity.

A shared dashboard target identifies the dashboard instance route and a stable view
id within that dashboard, as well as the spatial resource. This distinguishes two
maps that happen to appear on the same dashboard. Extend the host's existing
`api.navigate` and query-state handling rather than introducing a competing router.
The SDK asks the host to construct an authorized route and receives initial location
state from it. Query/time filters use existing dashboard query-state semantics. Camera changes
update the address bar after a bounded debounce with `history.replaceState`, preserving
host history state and unrelated query parameters. Cartesian links expose X/Y and
zoom; geographic links expose latitude/longitude and zoom (plus bearing/pitch where
supported). The recipient's viewport determines visible tile coverage from that
camera; cached or prefetched tile ids are not part of a shared location. Normal
panning must not flood the browser Back stack.

Two explicit link modes apply to arbitrary objects:

- **View** preserves the camera and may select a stable object. It stays at the
  shared area even if the object later moves; it is not a historical telemetry
  snapshot. If the selected object disappears, retain the valid view and explain
  that selection is unavailable.
- **Object** resolves a stable identity through its provider when opened and centers
  its current position. This does not enable continuous camera tracking implicitly.
  Missing or unauthorized objects have explicit unavailable/denied states.

Apply restored state after the authorized resource is ready, ahead of saved camera
preferences or default fit-to-bounds. Subsequent frame/telemetry refreshes must not
reset that camera. A map can still offer Home or explicit object tracking as user
actions. A tile address identifies a bounded region inside the resource's coordinate
version; the adapter converts it to a camera without conflating a tile's content
revision with the long-lived location identity.

A spatial resource is a named visualization dataset inside the existing deployment,
not a tenant or a new authorization boundary. Its host-owned descriptor supplies
resource id, coordinate-space id and immutable coordinate version, bounds, units,
axis convention, default camera, zoom range, supported payload format and budgets.
The host resolves resource ids to authorized providers; links never supply backend
URLs or credentials. Keep these boundaries:

- Location and camera: a versioned location value describes resource, coordinate
  space/version, center and zoom. Geographic adapters additionally own bearing and
  pitch. The host route serializes locations and the SDK asks the host to navigate
  or share; packages do not replace the application's URL or history themselves.
- Tile source: manifest, cancellable bounded tile reads, content revisions and
  targeted invalidations. Cache identity includes resource, coordinate space/version,
  tile address and payload format. Publication generation fences coherent reads;
  changing telemetry does not invalidate geometry. Close/dispose releases requests,
  subscriptions and cache state when a dashboard unmounts or its resource changes.
- Presentation adapter: decode payloads, create existing layer specs, resolve stable
  entity picks and details. Network topology supplies schema 3, persistent world
  placement, bounded ELK detail and SNMP overlays; floor plans supply plan layers;
  drone maps supply geographic tracks and sensor overlays.

Do not force every dataset into tiling: bounded dashboard frames remain valid input
for the existing SDK helpers. Add a tiled source only where dataset size requires
it. No whole-million-device frame may be sent to the browser to implement SDK LOD.

#4774 implements shared locations for its existing topology resource first, using a
renderer-independent Cartesian location codec. Its `topology-world` coordinate space uses a Y-down world of width `2^24`;
center coordinates are world units and zoom zero draws that width at 512 CSS pixels.
Its link contains a layout version,
not a telemetry snapshot or publication generation. Same-version links restore the
same center and scale with current authorized data. An unavailable layout yields a
visible explanation and Home; an explicit entity link resolves current coordinates.
The topology route supplies its resource and coordinate-space identity; its compact
URL uses `layout`, `x`, `y`, and `z`, with one decimal for coordinates and three for
zoom (trailing zeroes omitted). Older expanded links remain readable and are
canonicalized without discarding unrelated query state. Dashboard providers still
need explicit view/resource addressing when the route alone is not sufficient.
A later SDK host integration reuses this contract, adds provider registration and
proves a second, non-network resource before claiming a platform tile API. It must
not copy topology database tables or publish a second competing location format.

## Sequencing

Dashboard host plus carverauto/serviceradar-sdk-dashboard. Reuses #4847 plan-view work and #4774 camera/tiles; this follow-up does not block #4774.

## Delivery and isolation

Use treehouse and remote RBE with --config=remote; no Docker, local compilation
or new shell scripts. Automated database tests use srql-fixtures scratch DB only.
All fixtures are independently invented. Use migrations for schema changes.
Run required checks and make test before a PR; deliver every PR through no-mistakes.
