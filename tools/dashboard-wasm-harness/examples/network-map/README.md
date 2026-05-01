# Network Map Dashboard Package Example

This is a minimal TinyGo renderer for `dashboard-wasm-v1`. It emits a
ServiceRadar-owned `deck_map` render model using the `sites` sample frame.

## Build

```bash
cd tools/dashboard-wasm-harness/examples/network-map
./build.sh
```

The build writes:

- `dist/dashboard.wasm`
- `dist/manifest.json`
- `dist/sample-frames.json`
- `dist/sample-settings.json`

The script uses `TINYGO_BIN` when set. If TinyGo is not on `PATH`, it will use
the pinned TinyGo tarball already present in `go/tools/wasm-plugin-harness/`.

## Run In The Harness

```bash
cd tools/dashboard-wasm-harness
python3 -m http.server 4177
```

Open:

```text
http://localhost:4177/?manifest=./examples/network-map/dist/manifest.json&wasm=./examples/network-map/dist/dashboard.wasm&frames=./examples/network-map/dist/sample-frames.json&settings=./examples/network-map/dist/sample-settings.json
```
