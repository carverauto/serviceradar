# Change: Remove Legacy Collector URL Tokens And Harden Plugin Blob Delivery

## Why
Two bearer-token leak paths remain after the recent onboarding hardening work. Legacy collector enrollment still accepts secrets in URL query strings, and plugin blob upload/download URLs still embed signed bearer tokens in the request URL. Both flows expose tokens to logs, browser history, shell history, referrers, copied links, and intermediary observability systems.

## What Changes
- Remove the legacy collector enrollment GET endpoints that require `?token=...`.
- Require collector onboarding to use the existing bundle/download API paths that carry tokens in request headers or POST bodies.
- Move plugin blob upload/download from query-string bearer tokens to request header or body token transport.
- Stop generating plugin upload/download URLs that embed bearer tokens in the URL.
- Stop emitting plugin bearer download URLs in generated agent config.
- Update UI, API, CLI/client flows, tests, and docs to match the hardened transport.

## Impact
- Affected specs: `edge-onboarding`, `wasm-plugin-system`
- Affected code: `elixir/web-ng` collector and plugin package APIs, `elixir/serviceradar_core` plugin storage token helpers and agent config generation, plugin admin UI, tests, and docs
