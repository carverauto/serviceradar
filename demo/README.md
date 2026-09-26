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
