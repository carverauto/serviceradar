# Change: Improve plugin developer experience with bundle uploads

## Why
Plugin authors need a smoother workflow than uploading multiple files and embedding display contracts in YAML. A bundle-based flow improves developer experience, reduces import errors, and aligns with how SDKs and templates will be distributed.

## What Changes
- Add a first-class plugin bundle format (`.zip`) containing manifest, Wasm, and optional sidecar files.
- Allow `display_contract.json` and `config.schema.json` as sidecar files instead of embedding in `plugin.yaml`.
- Update the plugin import UX to accept a single bundle upload with validation feedback.
- Update the wasm plugin harness to produce a bundle artifact for example imports.
- Document the bundle format and import flow in plugin docs.

## Impact
- Affected specs: `wasm-plugin-system`
- Affected code: web-ng plugin upload flow, core plugin import validation, tools/wasm-plugin-harness, docs
- Related work: SDK repositories (`serviceradar-sdk-go`, `serviceradar-sdk-rust`) are tracked separately (see GH #2503, #2504)
