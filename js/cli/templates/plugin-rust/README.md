# __PLUGIN_NAME__

A ServiceRadar Wasm check plugin, written in Rust against
[`serviceradar-sdk-rust`](https://github.com/carverauto/serviceradar-sdk-rust).

## Build

```
cargo build --target wasm32-wasip1 --release
cp target/wasm32-wasip1/release/*.wasm plugin.wasm
```

Add the target once with `rustup target add wasm32-wasip1`.

## Validate and publish

```
serviceradar-cli plugin validate
serviceradar-cli auth login --instance https://<your-instance> --scope plugin.publish
serviceradar-cli plugin publish --instance https://<your-instance>
```

Publishing stages the package. An administrator approves it in
Settings -> Agents -> Plugins, where the capabilities `plugin.yaml` requests are
reviewed against what gets approved -- the approved set can be narrower than the
requested one, so ask for the least you need.

Check on it with:

```
serviceradar-cli plugin status --instance https://<your-instance> --id <package-id>
```

## Configuration

`Config` in `src/main.rs` is decoded from the per-assignment configuration an
operator sets. Add a `config.schema.json` next to `plugin.yaml` to have the UI
render inputs for your fields.
