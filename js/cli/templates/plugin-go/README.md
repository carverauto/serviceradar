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

## Updating the SDK

The SDK is vendored under `vendor/` because proxy.golang.org does not serve
`serviceradar-sdk-go` (every version 404s, including the `/v2` module path), so
a plain `go build` with network cannot resolve it. To move to a newer SDK
release, fetch it straight from GitHub and re-vendor:

```
GOPRIVATE='github.com/carverauto/*' go get github.com/carverauto/serviceradar-sdk-go/v2@latest
go mod vendor
```

`GOPRIVATE` routes the module around the proxy and takes its hash from your
`go.sum` instead of the checksum database, which has never seen this module.

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
