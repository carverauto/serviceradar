# Wasm Plugin Harness (TinyGo)

This harness builds a minimal TinyGo Wasm plugin that submits a simple OK result.

## Files

- `main.go`: TinyGo plugin source
- `plugin.yaml`: manifest for import
- `config.schema.json`: optional config schema
- `build.sh`: builds `dist/plugin.wasm`

## Build

```bash
./build.sh
```

On macOS, install TinyGo with Homebrew (`brew install tinygo`) or set `TINYGO_BIN` to a custom path.

Output:

- `dist/plugin.wasm`
- `dist/plugin.wasm.sha256`

## Import (manual)

1. Open the ServiceRadar UI.
2. Navigate to Admin -> Plugins -> Upload.
3. Upload `plugin.yaml` as the manifest.
4. Upload `config.schema.json` (optional).
5. Upload `dist/plugin.wasm` as the Wasm blob.
6. Approve the package (capabilities: get_config, log, submit_result).
7. Assign it to an agent.

Expected result payload:

- status: OK
- summary: "hello from wasm" (or "hello from wasm (config received)" if params are set)

## Notes

- `plugin.yaml` includes `schema_version: 1` and a `display_contract` that enables
  the default widget set (status badge, stat card, table, markdown, sparkline).
- The plugin uses `runtime: wasi-preview1` and the `env` host functions.
- To test config handling, set any JSON params during assignment; the plugin only checks that config is present.
