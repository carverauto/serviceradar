# Change: EventWriter processor contributions

## Why
EventWriter currently knows integration names directly. Core aliases modules such as
`ServiceRadar.EventWriter.Processors.PowerDNS`, `FalcoEvents`, and `TrivyReports`,
subscribes to their subjects, and maps batchers to their modules. That makes every new
add-on or sidecar a core-code change and blocks third-party integrations from shipping
their own ingestion behavior.

Add-ons and integrations need a first-class way to declare how their logs/events are
recognized, normalized, promoted, and correlated without loading arbitrary code into the
control plane.

## What Changes
- Add a package-owned EventWriter processor contribution manifest for native add-ons,
  Wasm plugins, and package-backed sidecars.
- Persist approved processor contributions in CNPG during package import, install, or
  registration. Core SHALL NOT call running add-ons at event-processing time to ask how
  records should be processed.
- Make processor contributions part of the platform output-contract registry. Packages
  request an output contract and bounded declarative projector; the platform assigns
  its finite route profile, broker subject slot, traffic class, partition rule, cost
  model, processor engine, destination, schema/display references, promotion rules,
  and device-correlation mappings. Packages never choose NATS subjects or physical
  streams.
- Replace producer-specific EventWriter aliases/routes with registry-driven dispatch
  keyed by the exact output-contract id, version, immutable bundle digest, and registry
  epoch carried in the trusted canonical binary record envelope.
  PowerDNS, Falco, Trivy, Bumblebee, endpoint inventory, and future integrations SHALL
  register processor contributions instead of being named in core pipeline code.
- Provide safe platform-owned processor engines for common payload classes:
  OCSF pass-through, OTEL log pass-through, JSON-to-OCSF mapping, finding promotion,
  scan activity promotion, and generic event/log promotion.
- Generalize package-owned catalog/artifact refresh contracts so Bumblebee-style
  catalogs are managed by platform catalog APIs instead of a Bumblebee-specific core
  worker.
- Update the in-repo add-on SDK and the Go/Rust plugin SDKs with typed builders and
  validators for processor and catalog contribution manifests.
- Keep arbitrary executable processors out of the initial contract. If custom logic is
  required, it must be expressed through a bounded declarative mapping or reference a
  platform-installed adapter by stable id during migration.
- Reuse the finite durable edge record streams and shared Broadway consumers from
  `unify-sweep-results-proto`; adding packages or contracts SHALL NOT create a
  proportional number of streams, consumers, connections, lanes, or RAFT groups.

## Impact
- Affected specs: `ingestion-routing`, `observability-signals`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/config.ex`
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/pipeline.ex`
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/*`
  - add-on/plugin package validation and import/approval paths
  - add-on/plugin SDK/package metadata docs
  - `elixir/serviceradar_core/lib/serviceradar/nats/jetstream_consumer.ex` and
    EventWriter Broadway producer wiring
  - `~/src/serviceradar-sdk-go`
  - `~/src/serviceradar-sdk-rust`
- Migration:
  - PowerDNS processor contribution becomes the reference implementation.
  - Falco, Trivy, Bumblebee, and endpoint inventory move to package-owned processor
    manifests.
  - Bumblebee catalog refresh moves to a generic package catalog/artifact refresh
    contract.
  - Existing generic platform processors for events, logs, OTEL metrics/traces, and
    flows remain core-owned because they are platform ingestion primitives.
- Related change: `unify-sweep-results-proto` owns the durable producer sink, output
  contract bundle, platform route profiles, transport-minimal broker metadata, and common
  EventWriter ingress on which contributions depend.
