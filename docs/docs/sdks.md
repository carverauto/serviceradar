---
title: SDKs & Plugin Development
---

# SDKs & Plugin Development

ServiceRadar publishes several SDKs for extending the platform — building Wasm plugins, integrations, and custom dashboards. This page is a brief overview of each SDK and when to reach for it.

The complete API reference, authoring guides, and code examples for every SDK live on the developer portal at [developer.serviceradar.cloud](https://developer.serviceradar.cloud). This page intentionally does not duplicate that reference.

## serviceradar-sdk-go

The Go SDK is for building ServiceRadar Wasm plugins and integrations in Go. It provides a higher-level API over the raw Wasm host ABI — structured execution and error handling, config decoding, HTTP/TCP/UDP wrappers that respect the agent's allowlists, gateway-mediated artifact staging, advisory-feed batch helpers, producer schedule contract helpers, and result builders for metrics, labels, and UI widgets. Plugins built with it compile to Wasm with TinyGo.

Use it when you want to write a custom checker, feed producer, or integration in Go and prefer an ergonomic SDK over hand-writing host imports.

See the full reference at [developer.serviceradar.cloud](https://developer.serviceradar.cloud).

## serviceradar-sdk-rust

The Rust SDK is the equivalent surface for building ServiceRadar Wasm plugins in Rust. It targets `wasm32-wasi` and exposes the same capability-based host functions, gateway-mediated artifact APIs, advisory-feed batch helpers, producer schedule contract helpers, and result-building helpers, with idiomatic Rust types and error handling.

Use it when you prefer Rust for plugin authoring, or when you want Rust's performance and type guarantees for a custom checker, feed producer, or integration.

See the full reference at [developer.serviceradar.cloud](https://developer.serviceradar.cloud).

## serviceradar-sdk-dashboard

The Dashboard SDK is for building custom dashboards and widgets that ServiceRadar's web UI imports and renders. Dashboards ship from a customer repository as a signed artifact plus a manifest; ServiceRadar provides the host shell, query execution, theming, and navigation.

Use it when you want to build bespoke visualizations or operational views on top of ServiceRadar data rather than authoring an edge checker.

See the full reference at [developer.serviceradar.cloud](https://developer.serviceradar.cloud), and the [Dashboard SDK](./dashboard-sdk.md) page for more detail.

## Related Pages

- [Wasm Plugins](./wasm-plugins.md) — conceptual overview of the sandboxed plugin model, the capability/permission system, and the upload/import workflow.
- [Dashboard SDK](./dashboard-sdk.md) — building browser-module dashboards for the ServiceRadar web UI.
