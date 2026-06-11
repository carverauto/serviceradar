# Change: Add serviceradar-sdk-otel — messaging-aware trace propagation SDK

## Why

Users wiring their applications for OTel lose trace continuity at messaging
hops: upstream OTel SDKs have no official NATS context propagation in any
major language, so NATS-based applications (including everything built
around ServiceRadar's edge/leaf transport story) produce disconnected
single-span traces — the same root-span epidemic we just fixed in our own
platform (refactor-otel-signal-correlation). ServiceRadar already solved
this internally (`ServiceRadar.Otel.Propagation` for Elixir NATS hops);
packaging that capability as a small per-language SDK turns a platform
internal into a product differentiator and gives add-on/plugin authors and
edge users a supported way to keep traces connected through NATS — with
Kafka as a follow-on adapter on the same API.

## What Changes

- New capability `sdk-otel`: thin, per-language SDK packages
  (`serviceradar-sdk-otel-go`, `-rust`, `-elixir` initially) providing:
  - a transport-agnostic W3C trace-context carrier API (inject/extract over
    header maps — traceparent/tracestate, baggage optional);
  - a NATS adapter: publish-side injection, subscribe-side extraction, and
    optional producer/consumer span helpers with messaging.* semconv
    attributes (messaging.system=nats, destination, operation);
  - ServiceRadar-ready defaults and examples (collector endpoints, incl.
    the edge collector add-on's local endpoint convention).
- API designed so a Kafka adapter (headers-based, same carrier contract)
  lands later without breaking changes.
- Dogfooding: platform components migrate from bespoke propagation glue to
  the SDK (core-elx adopts the Elixir package; Go services and the agent
  use the Go package; rust/addon-sdk re-exports the Rust crate for add-on
  authors).
- Publishing: hex / crates.io / Go module paths following the existing
  plugin-sdk-go and dashboard-sdk publishing patterns.

## Impact

- Affected specs: new `sdk-otel` capability.
- Affected code: new sdk packages (locations per language conventions:
  `rust/sdk-otel` or addon-sdk subcrate, `go/pkg/sdk/otelmsg` or separate
  module, Elixir package extracted from
  `elixir/serviceradar_core/lib/serviceradar/otel/propagation.ex`).
- Builds on: `refactor-otel-signal-correlation` (tasks 4.1, 10.5 — NATS
  propagation internals + edge self-telemetry convention); complements
  `add-nats-leaf-edge-telemetry` (future).
- Related precedent: `plugin-sdk-go` spec, `add-native-addon-rust-sdk`,
  `add-dashboard-sdk-npm-publishing`.
