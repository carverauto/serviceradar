## 1. Agent

- [x] 1.1 `addon.Spec.StateDir`; `addonStateDir(runtimeRoot, id)` = `<runtime root>/addons/<id>/state`, empty for an unsafe id.
- [x] 1.2 Supervisor creates the directory (0700) at spawn and exports `SERVICERADAR_ADDON_STATE_DIR`; failure logs and launches without it.
- [x] 1.3 Unit tests: env replaced once, blank dir leaves env alone, directory created private and idempotent, layout beside `versions/`.

## 2. Anomaly add-on

- [x] 2.1 `resolve_checkpoint_settings_in(config, state_dir)`: explicit path > `<state dir>/checkpoint.json` > off.
- [x] 2.2 `write_checkpoint` creates a missing parent directory.
- [x] 2.3 Unit tests for the resolution order and the parent-directory creation.
- [x] 2.4 Version 0.3.9 (`addon.yaml`, `ADDON_VERSION`, contract test pins); `checkpoint_path` schema description.

## 3. Docs and spec

- [x] 3.1 `docs/docs/native-addons.md` on-host layout shows `state/` and the env contract.
- [x] 3.2 `docs/docs/anomaly-engine.md` "Restart Checkpoint" section with the resolution order.
- [x] 3.3 `edge-architecture` delta: native add-on state directory requirement.

## 4. Verification

- [ ] 4.1 After the agent and 0.3.9 roll: `checkpoint.json` appears under `addons/anomaly/state/` on a host agent, and an add-on upgrade re-warms (series count non-zero right after `configure()`, open episodes cleared by the producer rather than stale-closed).
- [ ] 4.2 Remove the interim explicit `checkpoint_path` from the demo profile once 0.3.9 is on the fleet, so the default path is the one in use.
