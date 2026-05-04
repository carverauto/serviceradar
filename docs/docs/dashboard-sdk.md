---
id: dashboard-sdk
title: Dashboard SDK
sidebar_label: Dashboard SDK
description: React-first SDK for browser-module dashboards loaded by ServiceRadar web-ng. Canonical reference lives on the developer portal.
---

# Dashboard SDK

`@serviceradar/dashboard-sdk` is the customer-facing surface for building
browser-module dashboards that ServiceRadar imports, verifies, and renders.
Dashboards ship from a customer repository as a signed `renderer.js` artifact
plus a manifest; ServiceRadar handles the host shell, SRQL execution, frame
transport, theme, navigation, and Mapbox/deck.gl injection.

The reference implementation is the UAL Network Map at `~/src/ual-dashboard`.

## Canonical reference

The canonical Dashboard SDK reference — including the React hook surface
(`useDashboardQueryState`, `useFrameRows`, `useFilterState`, `useIndexedRows`,
`useDeckMap`, `useDeckLayers`, `useMapPopup`), the composed UAL pattern, the
Arrow IPC and SRQL primitives, the WASM render-model path, and the local
harness — lives on the ServiceRadar developer portal:

[**Dashboard SDK on developer.serviceradar.cloud**](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk)

The developer portal is the source of truth for SDK documentation. This page
exists so that operators reading the main ServiceRadar docs can discover where
dashboards are authored. SDK usage examples, hook signatures, and pattern
guidance update on the developer portal as the SDK evolves; the main docs
focus on operating ServiceRadar deployments rather than building plugins
against them.

## Related ServiceRadar Docs

- [WiFi Map (local Compose)](./wifi-map-local-compose.md) — running the
  reference customer dashboard against a local stack.
- [SRQL Reference](./srql-language-reference.md) — the query language that
  dashboards use to drive their data frames.
- [Wasm Plugins](./wasm-plugins.md) — the WASM extension surface used by
  dashboard render-model packages.

## Repositories

- SDK source: <https://code.carverauto.dev/carverauto/serviceradar-sdk-dashboard>
- Reference dashboard: <https://code.carverauto.dev/carverauto/ual-dashboard>
- Developer portal: <https://developer.serviceradar.cloud>
