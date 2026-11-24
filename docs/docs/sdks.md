---
title: SDKs & Plugin Development
---

# SDKs & Plugin Development

ServiceRadar publishes several SDKs for extending the platform -- building Wasm plugins, integrations, custom dashboards, Solution Packs, and Vantage video ML workers. This page is a brief overview of each SDK and when to reach for it.

The complete API reference, authoring guides, and code examples for every SDK live on the developer portal at [developer.serviceradar.cloud](https://developer.serviceradar.cloud). This page intentionally does not duplicate that reference.

## serviceradar-sdk-go

The Go SDK is for building ServiceRadar Wasm plugins and integrations in Go. It provides a higher-level API over the raw Wasm host ABI -- structured execution and error handling, config decoding, HTTP/TCP/UDP wrappers that respect the agent's allowlists, gateway-mediated artifact staging, advisory-feed batch helpers, producer schedule contract helpers, first-class metric telemetry helpers, notifier delivery envelopes and credential helpers, and result builders for labels and UI widgets. Plugins built with it compile to Wasm with TinyGo.

Use it when you want to write a custom checker, feed producer, notifier, or integration in Go and prefer an ergonomic SDK over hand-writing host imports.

The module path is `github.com/carverauto/serviceradar-sdk-go/v2`. It is not
served by the public Go proxy or checksum database, so set `GOPRIVATE` and
`GONOSUMDB` for `github.com/carverauto/*` on every `go get` / `go mod` /
`tinygo build` invocation that resolves it; Go then fetches it directly from
GitHub instead of failing against the proxy/checksum database:

```
export GOPRIVATE='github.com/carverauto/*'
export GONOSUMDB='github.com/carverauto/*'
go get github.com/carverauto/serviceradar-sdk-go/v2@latest
```

Commit a `vendor/` tree (`go mod vendor`) so plugin builds do not need to
download modules at all.

See the full reference at [developer.serviceradar.cloud](https://developer.serviceradar.cloud).

## serviceradar-sdk-rust

The Rust SDK is the equivalent surface for building ServiceRadar Wasm plugins in Rust. It targets `wasm32-wasi` and exposes the same capability-based host functions, gateway-mediated artifact APIs, advisory-feed batch helpers, producer schedule contract helpers, first-class metric telemetry helpers, notifier delivery envelopes and credential helpers, and result-building helpers for non-metric plugin output, with idiomatic Rust types and error handling.

Use it when you prefer Rust for plugin authoring, or when you want Rust's performance and type guarantees for a custom checker, feed producer, notifier, or integration.

See the full reference at [developer.serviceradar.cloud](https://developer.serviceradar.cloud).

## Notifier plugins

Both the Go and Rust SDKs support the **notifier** plugin kind: a plugin that
delivers an alert to a destination the declarative provider tier cannot express -
one that needs request signing, an OAuth exchange, a non-HTTP transport, or
egress from inside a customer network.

Each SDK ships the delivery request and result envelopes, notifier intents, the
`notifications:` manifest-block builder and validator, config decoding against
the notifier's own `config_schema`, and credential helpers built around an opaque
secret reference that renders a placeholder through every formatting path. Both
emit exactly the ten manifest keys the platform validator accepts and both use
the same six canonical credential injection mode names, so a plugin author never
learns a spelling the host does not serve. Both also export the notifier contract
version on every result, so a version mismatch is detectable at dispatch.

The `notify:v1` capability is enforced by the agent, not only declared in the
manifest, and it is checked against the assignment's narrowed capability set
before the module is loaded.

See [Notification Plugins (Wasm)](./notification-plugin-authoring.md) for the
manifest contract, the credential rules, the two execution routes, and the
constraints that decide whether a destination can run on the edge at all.

## serviceradar-sdk-dashboard

The Dashboard SDK is for building custom dashboards and widgets that ServiceRadar's web UI imports and renders. Dashboards ship from a customer repository as a signed artifact plus a manifest; ServiceRadar provides the host shell, query execution, theming, and navigation.

Use it when you want to build bespoke visualizations or operational views on top of ServiceRadar data rather than authoring an edge checker.

See the full reference at [developer.serviceradar.cloud](https://developer.serviceradar.cloud), and the [Dashboard SDK](./dashboard-sdk.md) page for more detail.

## Solution Packs

Solution Packs are ed25519-signed, versioned, secret-free `.srpack` bundles (`pack_format_version: 1`) that package complete vertical monitoring and visual intelligence capabilities into a single installable artifact. A pack can combine:

- Declarative service and posture checks (`checks/*.json`)
- Stateful alert, event, and Zen rules (`rules/*.json`)
- Portable SRQL dashboards (`dashboards/*.json`) and Dashboard SDK browser modules (`dashboard_packages/`, `dashboard-browser-module-v1`)
- Vantage video ML pipeline definitions (`vantage_pipelines/*.json`) and observation schemas (`signal_schemas/*.json`)

Browse published first-party and community packs on the developer portal at [developer.serviceradar.cloud](https://developer.serviceradar.cloud), and validate, build, sign, and index your own packs locally using `serviceradar-cli` (`@carverauto/serviceradar-cli`). See [Solution Packs & Declarative Checks](./solution-packs.md) for the archive contract, secret-free credential slots, and GitOps promotion workflow.

## serviceradar-sdk-vantage

`serviceradar-sdk-vantage` is the video ML extensibility SDK for [ServiceRadar Vantage](./vantage.md). It enables operators and third-party developers to build and package custom camera analytics (such as ALPR, PPE compliance, hazard detection, or bay guidance) across three progressive compute ramps without forking ServiceRadar core:

- **Ramp 1 (Declarative VLM Pipelines)**: Zero-code structured JSON prompts run by `serviceradar-camera-vlm` against full-resolution cropped IDR keyframes around Stage 1 detections.
- **Ramp 2 (External `vantage.worker.v1` Workers)**: Out-of-process Rust or Python workers built with the SDK's Rust core crate (wrapping `serviceradar-media-core` H.264 decode and SHA-256 verification), Python PyO3 bindings, and a synthetic local development harness. Workers pull jobs from NATS JetStream, read sealed video blocks via execution-time scoped Fragment Read Grants, and require zero database credentials.
- **Ramp 3 (WASM Action Bridges)**: Connects structured Vantage observations (`in:camera_observations`) and OCSF events to sandboxed Wasm plugins for deterministic post-processing, watchlist enrichment, and northbound actions.

See [ServiceRadar Vantage (VMS)](./vantage.md) for the full architecture and the reference ALPR Solution Pack (`io.serviceradar.vantage-alpr`), and visit [developer.serviceradar.cloud](https://developer.serviceradar.cloud) for SDK guides.

## Related Pages

- [ServiceRadar Vantage (VMS)](./vantage.md) -- edge-native IP camera VMS, hybrid semantic search, and the 3-ramp Vantage ML extensibility model.
- [Solution Packs & Declarative Checks](./solution-packs.md) -- signed `.srpack` bundle format, `serviceradar-cli` packaging, and GitOps sync.
- [Wasm Plugins](./wasm-plugins.md) -- conceptual overview of the sandboxed plugin model, the capability/permission system, and the upload/import workflow.
- [Dashboard SDK](./dashboard-sdk.md) -- building browser-module dashboards for the ServiceRadar web UI.
