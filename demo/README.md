# ServiceRadar showcase demos

Self-running demos: Wasm plugins that simulate fleets (Wi-Fi, drones, PLCs),
inject faults on a timer or on demand, and feed the normal pipeline, plus
dashboard packages that read the result back through SRQL. The plan, the
requirements and the task list are in
`openspec/changes/add-showcase-demo-portfolio/`.

Nothing here ships with the product. Every target under `//demo` is visible
only inside `//demo`, and `//demo/fence:fence_test` checks that the product's
plugin inventory and Helm chart never name a demo artifact.

## Layout

| Path | What it is |
| --- | --- |
| `simkit/` | Deterministic simulation library shared by every demo plugin |
| `simkit/guard/` | Fails on publicly routable IPs and public DNS names in emitted records |
| `simkit/sourcetest/` | The contract every plugin `Source` + `Normalizer` must pass |
| `simkit/fixture/` | Renders simulator output as dashboard harness frames |
| `simkit/examples/sample/` | The smallest complete pack; the template for real ones |
| `simkit/internal/tinygocheck/` | Proves `simkit` compiles for wasip1 with the plugin toolchain |
| `pluginkit/` | Maps a `simkit.Batch` onto SDK calls: device discovery and OCSF fault events in the result, metric batches through `emit_telemetry` |
| `third_party/serviceradar-sdk-go/` | The Go SDK (v2.1.0 sources) every demo plugin builds against |
| `defs.bzl` | `demo_wasm_plugin` (TinyGo build + bundle) and `demo_publish` (signed publish) |
| `tools/demopublish/` | The publisher behind every `:publish` target |
| `tools/rulecheck/` | Evaluates a manifest's event alert rules the way the alert engine does, for tests |
| `hello-sim/` | The smallest demo plugin: the sample pack end to end, build to publish |
| `fence/` | The product fence test |

## How a demo plugin is put together

- **State is derived, not stored.** Plugin runs share nothing, so every value
  is a function of the pack seed, the asset and the time. Each run owns the
  window `(now - interval, now]`: it back-fills fine-grained samples on a grid
  inside that window (`Window.Grid`), emits inventory only when a slow cadence
  boundary falls inside it (`CadenceDue`), and emits the fault openings and
  resolvings that happen inside it (`Schedule.Transitions`). Consecutive runs
  therefore emit every sample and event exactly once, and restarts change
  nothing.
- **Faults** are declared per pack (`FaultSpec`): a period, phase, duration,
  seeded jitter, target selectors and metric overlays. `Schedule.CoverageGaps`
  checks a pack keeps an incident active or starting within ten minutes;
  every pack runs it over a simulated week. Presenter-injected faults arrive
  as `Override`s; `CheckInjection` rejects ones that would overlap another
  fault of the same kind on the same target, and scheduled faults are never
  suppressed.
- **Source boundary.** A plugin's `Source` produces device-native
  `Observation`s; its `Normalizer` maps them to product contracts (`Batch`:
  devices, metrics, events). The simulator is one `Source`. A customer
  deployment writes a real one against the same `sourcetest` contract and
  keeps the normalizer and the dashboard.
- **Addresses** must be private, documentation-range or non-public names, so
  demo sweeps and probes never reach the internet. Real vendor OUIs and real
  public places are fine.

## Commands

```
bazel test --config=remote //demo/...
bazel run --config=remote //demo/simkit/examples/sample:update_fixtures
```

The second regenerates the committed harness fixtures from the simulator after
a change; the `fixtures_drift_*_test` targets fail until it is run.

## Building and publishing a demo plugin

A demo plugin is a TinyGo module whose `go.mod` `replace`s `simkit`,
`pluginkit` and the SDK with their directories here, so the Wasm build is
offline and uses only declared inputs. `demo_wasm_plugin` builds it with the
first-party TinyGo toolchain and bundles it; `demo_publish` declares the run
target. Fault events carry `log_name: demo.fault` and the attributes
`asset_id`, `demo.fault.state` (`open`/`resolved`), `demo.fault.kind` and
`demo.fault.id`; a plugin's `alert_rules` match on those, and its tests prove
it with `tools/rulecheck`.

Publishing signs the bundle with the demo-only upload key, stages, uploads and
approves the package, enables the alert rules it proposes (the platform creates
them disabled), assigns it to an agent, and publishes the dashboard when the
demo has one. Every step checks current state first, so re-running with
unchanged artifacts changes nothing; a changed plugin needs a new `version` in
`plugin.yaml`. Secrets come from the environment at run time only:

```
SERVICERADAR_INSTANCE=https://<instance> \
SERVICERADAR_TOKEN=<operator token> \
PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE=~/.serviceradar/demo-plugin-signing/serviceradar-demo-v1.key \
PLUGIN_UPLOAD_SIGNING_KEY_ID=serviceradar-demo-v1 \
bazel run --config=remote --platforms=@io_bazel_rules_go//go/toolchain:darwin_arm64 \
  //demo/hello-sim:publish -- --agent-uid <agent uid> [--params-file params.json] [--interval 60]
```

`--platforms` builds the (pure Go) publisher for the Mac running it while RBE
still does the work; drop it on Linux. Pass `--dry-run` to build, sign and stop
before contacting the instance. `demo`'s values trust the key id
`serviceradar-demo-v1` and nothing else does.
