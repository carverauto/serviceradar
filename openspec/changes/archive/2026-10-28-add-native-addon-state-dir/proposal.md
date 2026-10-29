# Change: Hand every native add-on a persistent state directory

## Why

The anomaly add-on can checkpoint its per-series state and re-warm on restart,
but only when an operator sets `checkpoint_path`. Nothing sets it: no profile,
no assignment, no seeder, no chart. On the demo fleet the effect was visible on
the day add-on 0.3.8 rolled out: the upgrade and a later agent self-update each
cold-started the detector, the drift episodes it was tracking were never cleared
by the producer and were stale-closed by core, and every host was blind for
`min_samples` twice in one evening. A re-warm feature that depends on a host
path an operator has to know about is a feature that is off.

## What Changes

- The agent creates a per-add-on state directory beside the add-on's versions
  tree (`<runtime root>/addons/<id>/state`, mode 0700) before every spawn and
  exports it to the sidecar as `SERVICERADAR_ADDON_STATE_DIR`. It survives
  artifact upgrades, rollbacks and restarts.
- The anomaly add-on defaults its checkpoint to `checkpoint.json` inside that
  directory when `checkpoint_path` is unset. An explicit `checkpoint_path` still
  wins, and a missing parent directory is created on the first write.
- Add-on version 0.3.9; docs for the on-host layout and the checkpoint
  resolution order.

## Impact

- Affected specs: `edge-architecture` (ADDED requirement).
- Affected code: `go/pkg/agent/addon` (supervisor env + directory),
  `go/pkg/agent` (spec composition), `rust/anomaly-addon` (checkpoint
  resolution), `addons/anomaly-addon` (schema text, version), docs.
- No control-plane, schema or chart change: the default is derived on the host.
  The in-cluster Kubernetes agent does not run native add-ons and is unaffected.
- Rollout: agents on this release hand the directory to every add-on; add-ons
  older than 0.3.9 ignore the variable and behave as before.
