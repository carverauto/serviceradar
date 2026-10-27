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
- On upgrade, core converges every install, whatever mode it was in, once. See the
  [convergence design](design.md#decision-1-converge-once-in-the-migration-and-one-job)
  for compatibility seeding and announcement conditions, and
  [first-decision handling](design.md#decision-2-first-merged-decisions-are-reconciliations-not-transitions)
  for transition suppression.
- Removed: the mode setting and `availability_mode()`, the mode control and its Helm pin
  (`core.availability.modeControl`), the Settings rollout panel, the readiness
  conditions and the `availability_cutover_readiness` health check, the progression,
  shadow-entry, capture-backfill and cutover workers, the shadow decision table and the
  divergence report, the `Operator` switch, control, status and report commands and
  their Mix tasks, the legacy-mode mirror trigger, and the legacy transition publishers.
- The upgrade includes a one-time audited exception to "only the adopt action changes a
  source". See the [Armis compatibility decision](design.md#decision-1a-merged-armis-sources-on-an-install-that-never-cut-over)
  for the affected sources and accepted incomplete-rollout exceptions.
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
- Armis northbound: compatibility is preserved subject to the accepted exceptions in
  the Armis compatibility decision linked above.
