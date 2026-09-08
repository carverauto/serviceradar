---
title: SDKs & Plugin Development
---

# SDKs & Plugin Development

ServiceRadar publishes several SDKs for extending the platform — building Wasm plugins, integrations, and custom dashboards. This page is a brief overview of each SDK and when to reach for it.

The complete API reference, authoring guides, and code examples for every SDK live on the developer portal at [developer.serviceradar.cloud](https://developer.serviceradar.cloud). This page intentionally does not duplicate that reference.

## serviceradar-sdk-go

The Go SDK is for building ServiceRadar Wasm plugins and integrations in Go. It provides a higher-level API over the raw Wasm host ABI — structured execution and error handling, config decoding, HTTP/TCP/UDP wrappers that respect the agent's allowlists, gateway-mediated artifact staging, advisory-feed batch helpers, producer schedule contract helpers, first-class metric telemetry helpers, notifier delivery envelopes and credential helpers, and result builders for labels and UI widgets. Plugins built with it compile to Wasm with TinyGo.

Use it when you want to write a custom checker, feed producer, notifier, or integration in Go and prefer an ergonomic SDK over hand-writing host imports.

Fetching the module requires `GOPRIVATE=github.com/carverauto/serviceradar-sdk-go`
on every `go get` / `go mod` / `tinygo build` invocation that resolves it — the
module is not served via the public Go proxy, so without this Go fails against
the proxy/checksum database instead of fetching directly from GitHub:

```
export GOPRIVATE=github.com/carverauto/serviceradar-sdk-go
```

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

## Related Pages

- [Wasm Plugins](./wasm-plugins.md) — conceptual overview of the sandboxed plugin model, the capability/permission system, and the upload/import workflow.
- [Dashboard SDK](./dashboard-sdk.md) — building browser-module dashboards for the ServiceRadar web UI.
