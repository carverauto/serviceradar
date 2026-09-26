## ADDED Requirements

### Requirement: Demo packages are fenced from the product
Demo simulator plugins, scenario packs, dashboards, fixtures, alert rules and deploy targets SHALL live under `demo/` and SHALL NOT be included in any product build, first-party plugin inventory, Helm chart or release artifact.
Every `demo/` Bazel target is visible only within `//demo/...`, and demo plugins are signed with a demo-only upload key trusted solely by the `demo` instance.

#### Scenario: A product target depends on a demo target
- **WHEN** a target outside `//demo/...` declares a dependency on a `//demo/...` target
- **THEN** the build SHALL fail on visibility
- **AND** the demo fencing test SHALL report the offending target

#### Scenario: Release inventory is checked
- **WHEN** the fencing test inspects `build/wasm_plugins/plugin_inventory.bzl`, the Helm chart and the release manifests
- **THEN** it SHALL fail if any of them references a path under `demo/`

### Requirement: Demo data never derives from customer deployments
Demo scenario packs, simulators and fixtures SHALL be built from public information and invention and SHALL NOT contain data exported, replayed, sanitized or reshaped from a customer or partner deployment or dataset.
Public real-world reference data (airports, flight numbers, public coordinates, vendor product names and OUIs) is permitted.

#### Scenario: Pack uses public reference data
- **WHEN** a scenario pack places assets at a real airport and names real vendor equipment models
- **THEN** the pack SHALL be accepted by the demo checks

### Requirement: Simulated addresses are non-routable
Every IP address and host name a demo simulator or fixture emits SHALL be private (RFC 1918), a documentation range, or a non-public name, so that no platform probe in the `demo` namespace targets a real internet host.

#### Scenario: A simulator emits a routable address
- **WHEN** a simulator test or the fixture exporter produces a record containing a publicly routable IP address
- **THEN** the demo guard SHALL fail the test and name the record and field

#### Scenario: A simulator emits a public host name
- **WHEN** an emitted record contains a host name under a public DNS domain
- **THEN** the demo guard SHALL fail the test

### Requirement: Simulator state is derived from seed and time
A demo simulator SHALL compute every emitted value as a deterministic function of the scenario seed, the entity identity and wall-clock time, and SHALL NOT depend on state carried between plugin runs.

#### Scenario: Two runs at the same instant
- **WHEN** the same scenario pack is evaluated twice for the same timestamp
- **THEN** both evaluations SHALL produce identical records

#### Scenario: Monotonic counters survive restarts
- **WHEN** the agent restarts the plugin between two runs
- **THEN** counters emitted by the second run SHALL be greater than or equal to those emitted by the first

### Requirement: Faults are injected on a schedule and on demand
Every scenario pack SHALL schedule its own recurring faults so that an unattended demo produces incidents, and every demo plugin SHALL also expose fault injection as a plugin action so a presenter can trigger a declared fault from the dashboard.
Scheduled and injected faults SHALL travel the same path: the plugin emits an opening OCSF event to the events store, applies the fault to its telemetry, and emits a resolving event when the fault ends.
While a pack's schedule is enabled, at every instant at least one fault SHALL be active or SHALL begin within ten minutes, and faults of the same kind on the same target SHALL NOT overlap.

#### Scenario: A week of schedule is checked
- **WHEN** the fault-scheduler test evaluates a scenario pack over seven simulated days
- **THEN** it SHALL find no gap longer than ten minutes without an active or imminent fault
- **AND** SHALL find a resolving event for every opening event

#### Scenario: A fault opens and closes an alert
- **GIVEN** the demo's alert rules are installed
- **WHEN** a scheduled fault opens and later resolves
- **THEN** the platform SHALL open an alert from the opening event
- **AND** SHALL resolve that alert from the resolving event without operator action

#### Scenario: Presenter triggers a fault
- **GIVEN** a user permitted to invoke the plugin's fault-injection action
- **WHEN** the user triggers a declared fault on a target from the dashboard
- **THEN** the plugin SHALL emit the fault's opening OCSF event within seconds
- **AND** subsequent plugin runs SHALL apply the fault to the target's telemetry until it expires
- **AND** the plugin SHALL emit the resolving event when it expires or is ended early

#### Scenario: Injected fault on a busy target
- **WHEN** a fault of the same kind is already injected on the target
- **THEN** the injection SHALL be rejected with a distinguishable error
- **AND** no second opening event SHALL be emitted

### Requirement: Demo telemetry uses the standard pipeline
Demo simulators SHALL deliver metrics through plugin telemetry emission to NATS JetStream, inventory through device discovery results, and faults through plugin result events, and SHALL NOT write to any database directly.
Inventory for a steady fleet SHALL be emitted on a slow cadence (default every fifteen minutes) with stable identities, while position and process values travel as metrics.

#### Scenario: A drone moves
- **WHEN** a drone's position changes between runs
- **THEN** the simulator SHALL emit the new position as metric samples
- **AND** SHALL NOT re-emit the drone's inventory record outside its inventory cadence

### Requirement: Every demo runs offline from simulator fixtures
Each demo dashboard SHALL run in the dashboard dev harness without a live ServiceRadar, using committed fixtures generated by running the demo's simulator code natively against its scenario pack, including one fixture per headline fault.
A `diff_test` SHALL fail when committed fixtures are stale relative to the simulator.

#### Scenario: Simulator changes without regenerating fixtures
- **WHEN** a simulator change alters emitted records and the fixtures are not regenerated
- **THEN** the fixture `diff_test` SHALL fail and name the update target

#### Scenario: A sales engineer runs a demo on a laptop
- **WHEN** the dashboard dev server starts with no ServiceRadar reachable
- **THEN** the dashboard SHALL render its map, tables and incident state from fixtures
- **AND** its SRQL filter controls SHALL change the displayed rows

### Requirement: Demo video is replayed from licensed clips
Demo camera streams SHALL be served by the demo RTSP replayer from H.264 clips stored in object storage and listed in a clip lock file recording object key, sha256, duration and license; clips SHALL NOT be committed to the repository.
The replayer SHALL refuse objects absent from the lock file or whose digest does not match.

#### Scenario: A clip digest does not match
- **WHEN** the replayer fetches a clip whose sha256 differs from the lock file
- **THEN** it SHALL NOT serve that clip and SHALL report the mismatch

#### Scenario: A drone camera is viewed
- **WHEN** a viewer opens a drone camera from a demo dashboard
- **THEN** the stream SHALL flow from the replayer through the agent RTSP reader, the core-elx relay and WebRTC egress like any real camera

### Requirement: Drone fleet demo with multiview overlay
The drone fleet demo SHALL show drones, ground stations and geofence polygons on a map, and SHALL provide a toggleable overlay anchored to a corner of the map that plays several drone camera streams in a grid.
Selecting a drone on the map SHALL highlight its tile, and selecting a tile SHALL focus its drone on the map; hiding the overlay SHALL close its stream sessions.

#### Scenario: Overlay toggled on
- **WHEN** the user enables the camera overlay
- **THEN** the dashboard SHALL open streams for the visible drones up to the tile limit and play them concurrently

#### Scenario: Overlay toggled off
- **WHEN** the user hides the overlay
- **THEN** every stream session the overlay opened SHALL be closed

#### Scenario: Lost-link fault
- **WHEN** a scheduled lost-link fault affects a drone
- **THEN** the map SHALL show its last known position as stale
- **AND** its tile SHALL show a lost-link state
- **AND** an alert SHALL open for that drone

### Requirement: Wi-Fi campus twin demo
The Wi-Fi demo SHALL present an airport venue with controllers, access points, an indoor floorplan, client load driven by a fictional carrier's flight schedule, RF health and roaming, using the platform's Wi-Fi map result contract and SRQL Wi-Fi entities.
It SHALL NOT be derived from any customer's Wi-Fi dataset or dashboard, and its flights SHALL use an airline designator no real airline holds.

#### Scenario: Channel saturation fault
- **WHEN** a scheduled channel-saturation fault affects a site
- **THEN** the affected access points SHALL show elevated utilization on the floorplan and map
- **AND** an alert SHALL open and later resolve for that site

### Requirement: OT process demos share one PLC simulator
The airport baggage-handling demo and the well-pad demo SHALL be scenario packs for a single PLC simulator plugin, each with its own dashboard, and plan-view dashboards SHALL render without a geographic basemap.

#### Scenario: Conveyor jam
- **WHEN** a scheduled jam fault affects a conveyor controller
- **THEN** the baggage dashboard SHALL highlight the controller and its upstream conveyors
- **AND** SHALL list the most recent bags routed through that conveyor

#### Scenario: Pressure spike with radio fade
- **WHEN** a scheduled pressure-spike fault coincides with degraded radio link on a well pad
- **THEN** the well-pad dashboard SHALL show both signals on the affected asset
- **AND** the topology view SHALL show the RTU's path through its radio to its backhaul tower

### Requirement: Demos deploy to the demo namespace through Bazel
Each demo SHALL provide a Bazel run target that publishes its signed plugin bundle and dashboard package to the `demo` instance, installs its alert rules and assigns its plugin, reading the operator token from the client environment at run time.

#### Scenario: Publishing a demo
- **WHEN** an operator runs a demo's publish target with a valid token for the `demo` instance
- **THEN** the plugin, dashboard, alert rules and assignment SHALL be present in `demo`
- **AND** re-running the target with unchanged artifacts SHALL succeed without creating duplicates

### Requirement: Demo plugins separate the source from normalization
Every demo plugin SHALL obtain device observations through a source interface whose simulated implementation produces the same device-native shapes a real device or vendor API returns, and SHALL map observations to product contracts in a normalizer shared by simulated and real sources.
Demo plugins and dashboards SHALL use only product result contracts and product SRQL entities, never demo-only schemas.

#### Scenario: Swapping in a real source
- **WHEN** a real source implementation passes the plugin's source contract test
- **THEN** the plugin SHALL emit the same contracts with the real source as with the simulated one
- **AND** the demo dashboard SHALL render the real data without modification

### Requirement: Drone video carries real detections
The drone demo SHALL run a real object-detection worker on its relayed camera streams through the platform's camera analysis pipeline, draw the resulting detections on the matching camera tiles, and raise alerts for configured detections.
Detections SHALL come from inference on the video, never from painted or scripted boxes.

#### Scenario: Vehicle detected
- **WHEN** the detector reports a vehicle above the configured confidence
- **THEN** the drone's camera tile SHALL draw the detection box on the frame it came from
- **AND** an alert SHALL open through the demo's event-signal rules

#### Scenario: Detections stop
- **WHEN** no matching detection arrives for the configured quiet window
- **THEN** the alert SHALL resolve without operator action

#### Scenario: No viewers
- **WHEN** no relay session is active for a drone camera
- **THEN** no analysis SHALL run for that camera

### Requirement: Presenter strip shows and triggers faults
Each demo dashboard SHALL show the active incident, a countdown to the next scheduled fault, and a trigger control for each fault the plugin's action descriptors declare, and every trigger SHALL invoke the plugin action rather than change dashboard state directly.

#### Scenario: Waiting for the next fault
- **WHEN** no fault is active
- **THEN** the strip SHALL show the time remaining until the next scheduled fault

#### Scenario: No fault schedule published
- **WHEN** the simulator's schedule metrics are absent, as with a real source
- **THEN** the strip SHALL hide the countdown without error
- **AND** the strip SHALL still show the active incident from the product's alerts

#### Scenario: User without action permission
- **WHEN** a user who may not invoke the plugin's actions opens the dashboard
- **THEN** the strip SHALL show incident and countdown without trigger controls

#### Scenario: Dashboard reacts to the injected fault
- **WHEN** a presenter triggers a fault
- **THEN** the incident banner, map highlight and detail panel SHALL reflect it within seconds of the opening event, without waiting for the next scheduled frame refresh
