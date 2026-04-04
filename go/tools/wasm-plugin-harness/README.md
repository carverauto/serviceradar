# Wasm Plugin Harness (TinyGo)

This harness builds a minimal TinyGo Wasm plugin that submits a simple OK result.

## Files

- `main.go`: TinyGo plugin source
- `plugin.yaml`: manifest for import
- `config.schema.json`: optional config schema
- `display_contract.json`: optional display contract (UI widgets)
- `build.sh`: builds the Bazel-managed plugin bundle outputs

## Build

```bash
./build.sh
```

Output:

- `bazel-bin/build/wasm_plugins/hello_wasm_bundle.zip`
- `bazel-bin/build/wasm_plugins/hello_wasm_bundle.sha256`
- `bazel-bin/build/wasm_plugins/hello_wasm_bundle.metadata.json`

## Import (manual)

1. Open the ServiceRadar UI.
2. Navigate to Admin -> Plugins -> Upload.
3. Extract `plugin.yaml` from the bundle and upload it as the manifest.
4. Upload `config.schema.json` (optional).
5. Upload `display_contract.json` (optional).
6. Extract `plugin.wasm` from the bundle and upload it as the Wasm blob.
6. Approve the package (capabilities: get_config, log, submit_result).
7. Assign it to an agent.

Expected result payload:

- status: OK
- summary: "hello from wasm" (or "hello from wasm (config received)" if params are set)

## Notes

- `display_contract.json` enables the default widget set (status badge, stat card,
  table, markdown, sparkline).
- The plugin uses `runtime: wasi-preview1` and the `env` host functions.
- To test config handling, set any JSON params during assignment; the plugin only checks that config is present.
