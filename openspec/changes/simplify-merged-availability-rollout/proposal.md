# Change: Simplify the merged device availability rollout

## Why

`add-merged-device-availability` shipped merged availability as a staged migration so it
could be validated on the demo deployment: `legacy` -> `shadow` (with a divergence
report) -> `cutover` -> `authoritative`, later made to progress automatically under an
`auto | hold_legacy | hold_shadow` control with readiness conditions and a 24-hour health
warning. That validation is done. The staging was a development and testing process; it
must not ship to users as modes, controls, readiness conditions, a shadow table or
operator switches.

## What Changes

- **BREAKING (internal):** the availability modes, their switches and the automatic
  progression are removed. Core always runs merged availability: the resolver owns
  `availability_state` and `is_available`, and emits each transition.
- On upgrade, core converges every install, whatever mode it was in, once: a migration
  records the pre-merge value of every device that has none in the compatibility store
  (installs in `legacy` or `shadow` only), drops the rollout objects, and enqueues one
  full resolve whose first decision per device emits no per-device event, followed by
  one reconciliation summary. A fresh install needs no special case.
- Removed: the mode setting and `availability_mode()`, the mode control and its Helm pin
  (`core.availability.modeControl`), the Settings rollout panel, the readiness
  conditions and the `availability_cutover_readiness` health check, the progression,
  shadow-entry, capture-backfill and cutover workers, the shadow decision table and the
  divergence report, the `Operator` switch, control, status and report commands and
  their Mix tasks, the legacy-mode mirror trigger, and the legacy transition publishers.
- One-time exception to "only the adopt action changes a source": on an install that never
  cut over (`legacy` or `shadow`), an Armis source in `merged` semantics with no agent
  pushed the mirror of the legacy value; the upgrade sets it to `legacy` semantics, with
  an audit row, so it keeps pushing exactly that value instead of switching silently.
- Kept: the per-source Armis northbound choice (agent | `legacy` semantics | `merged`
  semantics) as a product setting, and with it the compatibility store
  `device_availability_legacy` and the legacy writers that maintain it, because `legacy`
  semantics push exactly that value. Per-agent results stay first-class and are never
  rewritten. The user's earlier decisions stand: the Wi-Fi controller wins, a per-device
  agent pin outranks operator policy, `transition_events` stays a deployment setting
  with the sweep-group flag filter, a log-only write-violation backstop, and `unknown`
  keeps the last boolean.

## Impact

- Affected specs: `device-inventory`, `build-web-ui`, `sweeper`,
  `sync-service-integrations` (all requirements introduced or modified by
  `add-merged-device-availability`). This change archives after
  `add-merged-device-availability`.
- Affected code: `elixir/serviceradar_core` (availability resolution, writers, workers,
  migration `20261026220000_converge_merged_availability`), `elixir/web-ng` (Availability
  Sources settings, Armis source settings), `helm/serviceradar` (`modeControl` removed,
  `expectedVersion` bumped), `docs/merged-device-availability.md` (replaces the cutover
  runbook).
- Armis northbound: what every existing source pushes is unchanged.
