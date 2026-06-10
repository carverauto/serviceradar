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
- Introduce an approved processor registry that EventWriter uses to discover NATS
  subjects, batch routing, processor engine, destination, schema/display references,
  promotion rules, and device-correlation mappings.
- Replace producer-specific EventWriter aliases/routes with registry-driven routing.
  PowerDNS, Falco, Trivy, Bumblebee, endpoint inventory, and future integrations SHALL
  register processor contributions instead of being named in core pipeline code.
- Provide safe platform-owned processor engines for common payload classes:
  OCSF pass-through, OTEL log pass-through, JSON-to-OCSF mapping, finding promotion,
  scan activity promotion, and generic event/log promotion.
- Keep arbitrary executable processors out of the initial contract. If custom logic is
  required, it must be expressed through a bounded declarative mapping or reference a
  platform-installed adapter by stable id during migration.

## Impact
- Affected specs: `ingestion-routing`, `observability-signals`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/config.ex`
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/pipeline.ex`
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/*`
  - add-on/plugin package validation and import/approval paths
  - add-on/plugin SDK/package metadata docs
- Migration:
  - PowerDNS processor contribution becomes the reference implementation.
  - Falco, Trivy, Bumblebee, and endpoint inventory move to package-owned processor
    manifests.
  - Existing generic platform processors for events, logs, OTEL metrics/traces, and
    flows remain core-owned because they are platform ingestion primitives.
