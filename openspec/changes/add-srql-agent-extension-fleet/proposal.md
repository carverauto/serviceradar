# Change: Query native add-on and WASM plugin fleet health

## Why

Operators need SRQL access to desired and observed agent extension state, including freshness and version drift (GitHub issue 5038).

## What Changes

- Execute `addon_fleet` through the existing scoped Ash fleet model.
- Add `plugin_fleet` for partition-bound WASM assignments and runtime evidence.
- Compile validated fleet read plans, expose safe scalar fields, and retain signed cursor pagination and Arrow responses.
- Add permission gates, visualization metadata, query catalog entries, documentation, and behavioral coverage.

## Impact

- Affected specs: srql
- Affected code: rust/srql, elixir/web-ng
- Existing `addon_statuses` and native fleet UI behavior remain compatible.
