# WASM Plugins

ServiceRadar plugins are compiled to WebAssembly using TinyGo and published to a
ServiceRadar instance via `serviceradar-cli`.

## Prerequisites

- **Go 1.21+** — required for running tests and the standard-build stub
- **TinyGo** — required to compile `plugin.wasm`; install from <https://tinygo.org/getting-started/install/>
- **serviceradar-cli** — the CLI tool used to publish plugins to an instance

## Build

Each plugin lives in its own subdirectory. Using `starlink` as the canonical example:

```sh
cd go/cmd/wasm-plugins/starlink
tinygo build -o plugin.wasm -target=wasi -gc=conservative -scheduler=none -no-debug ./
```

Run the tests (uses the standard Go toolchain, not TinyGo):

```sh
go test ./...
```

## Publish

```sh
serviceradar-cli plugin publish --instance <instance-url> --wasm plugin.wasm --yes
```

Replace `<instance-url>` with the URL of your ServiceRadar instance.

## Plugins

| Directory | What it monitors |
|---|---|
| `alienvault-otx` | AlienVault OTX threat-intelligence indicators |
| `awx` | Ansible AWX / Automation Controller — job inventory sync |
| `axis` | Axis network cameras — stream health and device signals |
| `dusk-checker` | Dusk network node liveness and peer health |
| `netbox` | NetBox DCIM/IPAM — inventory sync |
| `opentext-nom` | OpenText Network Operations Manager — device and interface health |
| `proxmox` | Proxmox VE — VM, container, and node metrics |
| `sample-northbound` | Reference northbound plugin showing the integration skeleton |
| `starlink` | Starlink satellite terminals — throughput, latency, GPS, and alerts |
| `unifi-protect` | UniFi Protect — camera streams and motion events |

## TinyGo WASI constraint: lazy-initialize global maps

TinyGo's WASI target suppresses `_start`, so global map literals are never
executed. **Do not initialize maps at the `var` declaration level.** Instead,
initialize them on first use inside a dedicated `init` function called from your
plugin entry point.

See `starlink/telemetry.go` — `initMetricMaps()` — for the canonical pattern:

```go
var terminalMetrics map[string]metricSpec

func initMetricMaps() {
    if terminalMetrics != nil {
        return
    }
    terminalMetrics = map[string]metricSpec{
        // ...
    }
}
```

Call `initMetricMaps()` (or your equivalent) at the top of the function that
first needs the map. This works identically under both TinyGo/WASI and the
standard Go toolchain used for tests.
