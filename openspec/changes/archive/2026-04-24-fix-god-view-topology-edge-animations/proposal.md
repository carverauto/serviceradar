# Change: Fix God-View topology edge animations

## Why
GitHub issue [#2894](https://github.com/carverauto/serviceradar/issues/2894) reports that God-View edge particle animations are not visible in the deck.gl topology view. This removes a key directional/activity cue and makes topology state harder to interpret.

## What Changes
- Add explicit UI requirements for God-View edge particle visibility.
- Require visual contrast between animated particles and base edge strokes.
- Require render ordering so particles are not obscured by static edge lines.
- Define acceptance behavior for normal and reduced-motion rendering modes.

## Impact
- Affected specs: `build-web-ui`
- Affected code (expected): `elixir/web-ng` God-View topology rendering components and deck.gl layer configuration
