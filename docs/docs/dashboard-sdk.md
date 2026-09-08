---
id: dashboard-sdk
title: Dashboard SDK
sidebar_label: Dashboard SDK
description: React-first SDK for browser-module dashboards loaded by ServiceRadar web-ng. Canonical reference lives on the developer portal.
---

# Dashboard SDK

`@carverauto/serviceradar-dashboard-sdk` is the customer-facing surface for
building browser-module dashboards that ServiceRadar imports, verifies, and renders.
Dashboards ship from a customer repository as a signed `renderer.js` artifact
plus a manifest; ServiceRadar handles the host shell, SRQL execution, frame
transport, theme, navigation, and Mapbox/deck.gl injection.

## Canonical reference

The canonical Dashboard SDK reference — including the React hook surface
(`useDashboardQueryState`, `useFrameRows`, `useFilterState`, `useIndexedRows`,
`useMapboxMap`, `useDeckMap`, `useDeckLayers`, `useMapPopup`), composed map
patterns, the Arrow IPC and SRQL primitives, the WASM render-model path, and
the local harness — lives on the ServiceRadar developer portal:

[**Dashboard SDK on developer.serviceradar.cloud**](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk)

The developer portal is the source of truth for SDK documentation. This page
exists so that operators reading the main ServiceRadar docs can discover where
dashboards are authored. SDK usage examples, hook signatures, and pattern
guidance update on the developer portal as the SDK evolves; the main docs
focus on operating ServiceRadar deployments rather than building plugins
against them.

Custom dashboard packages that provide SRQL editing or query-building UI should
fetch `GET /api/srql/catalog` from the host ServiceRadar deployment for entity,
field, control-token, and operator metadata. Treat that catalog JSON as the
canonical client-side reference rather than shipping a separate SRQL field map
inside the package.

## Stats frames and row paging

`in:composite_results stats:count() as n by check,verdict` is a GROUP BY, not
a truncated row dump. Do not page it, and do not treat a short result as a
ceiling. Vantage rollups use `by input_key, input_value` (optional
`input_stale`), which unnests `inputs` server-side.

Row frames that can exceed the host page size should call `api.srql.page`
(SDK 0.2.0: `useDashboardFramePagination`) with the signed cursor from
`frame.pagination`. Do **not** put `cursor:` in the query string. Device
labels for a paged results frame come from `in:devices uid:(…)` with at most
200 uids, matching the SRQL IN-list cap.

The host, examples, and React hook contract live on the
[developer portal Dashboard SDK page](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk).

## Related ServiceRadar Docs

- [SRQL Reference](./srql-language-reference.md) — the query language that
  dashboards use to drive their data frames.
- [Wasm Plugins](./wasm-plugins.md) — the WASM extension surface used by
  dashboard render-model packages.

## Where to author dashboards

The [ServiceRadar developer portal](https://developer.serviceradar.cloud) is the
source of truth for the Dashboard SDK, including installation, the React hook
surface, and pattern guidance.
