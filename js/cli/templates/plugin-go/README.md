# __PLUGIN_NAME__

A ServiceRadar Wasm check plugin, written in Go against
[`serviceradar-sdk-go`](https://github.com/carverauto/serviceradar-sdk-go).

## Build

The plugin is compiled by TinyGo, not the stock Go toolchain:

```
tinygo build -target=wasi -no-debug -o plugin.wasm ./
```

`main_stub.go` carries a `!tinygo` build tag so `go vet` and editor tooling keep
working on the host toolchain.

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

`Config` in `main.go` is decoded from the per-assignment configuration an
operator sets. Add a `config.schema.json` next to `plugin.yaml` to have the UI
render inputs for your fields.
