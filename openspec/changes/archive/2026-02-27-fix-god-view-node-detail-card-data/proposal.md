# Change: Fix God-View node detail card data contract

## Why
GitHub issue [#2929](https://github.com/carverauto/serviceradar/issues/2929) reports that God-View node detail cards are missing IP addresses and other node metadata on click. This removes core operator context needed for topology triage and suggests contract drift between topology snapshot payloads and deck.gl detail rendering.

## What Changes
- Define a God-View node-detail metadata contract in the `build-web-ui` capability so deck.gl node details consistently include identity and network context fields when available.
- Require consistent fallback behavior for absent fields (explicit `unknown`/placeholder rendering) while preserving card visibility.
- Require regression coverage for click-selection detail rendering so missing-IP regressions are caught before release.

## Impact
- Affected specs: `build-web-ui`
- Affected code (expected):
  - `elixir/web-ng/assets/js/lib/god_view/rendering_selection_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_tooltip_methods.js`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - God-View snapshot/renderer tests under `elixir/web-ng/assets/js/lib/god_view/`
