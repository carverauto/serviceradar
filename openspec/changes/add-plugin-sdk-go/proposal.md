# Change: Add Go plugin SDK

## Why
Plugin authors need an ergonomic Go SDK that hides Wasm host-guest plumbing and produces valid `serviceradar.plugin_result.v1` payloads. The SDK also needs to expose event/alert promotion controls so plugin logic can drive the log → event → alert pipeline described in GH #2502 and tracked in GH #2535.

## What Changes
- Introduce a Go SDK public API for ServiceRadar plugins targeting the agent Wasm runtime.
- Provide config decoding, result-building helpers, logging, and event/alert promotion APIs.
- Wrap host function calls (HTTP and stream I/O) with Go-friendly interfaces.
- Export memory helpers (`alloc`, `dealloc`) and a standard execution entrypoint for TinyGo plugins.
- Document the SDK usage and add example plugins in the SDK repo.

## Impact
- Affected specs: `plugin-sdk-go` (new capability)
- Affected code: `serviceradar-sdk-go` repository, docs updates, example plugin templates
- Related work: `add-plugin-devx-bundles` (bundle packaging handled separately)
