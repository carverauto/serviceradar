# Change: Harden edge artifact mirroring and NATS leaf bundle generation

## Why
The current edge artifact mirroring path still trusts automatic HTTP redirects and buffers mirrored artifacts in memory before enforcing the size limit. The edge-site NATS leaf setup script also interpolates site names directly into shell source, which can turn an operator-run setup step into shell injection.

## What Changes
- Disable implicit redirect following for mirrored release artifacts and validate every redirect target before following it.
- Stream mirrored artifact downloads with a hard byte limit instead of buffering the full response in memory.
- Make artifact basename handling fail closed for URLs without a path.
- Generate NATS leaf setup/readme content with shell-safe quoting for edge-site names and related interpolated values.

## Impact
- Affected specs: `edge-architecture`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/edge/release_artifact_mirror.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/nats_leaf_config_generator.ex`
