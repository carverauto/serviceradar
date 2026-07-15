# Change: Fail closed on live AWX launch drift

## Why

The restricted AWX dispatch-marker survey makes the ServiceRadar launch contract
reviewable, but it only validates the reviewed representation. The current
secure-launch path can persist a run and dispatch `awx.launch_job` without
first reading the live AWX template, project, inventory, credentials, execution
environment, and selected hosts through the assigned edge agent. A template or
membership change after review could therefore alter what a user is allowed to
run.

## What Changes

- Add a read-only, agent-routed `awx.fetch_launch_preflight` verb that returns a
  redacted, canonical snapshot of the live job template and the exact selected
  hosts.
- Add a `LiveAwxLaunchPreflight` gate before any secure execution/run is
  persisted. It compares the live snapshot to the approved callback binding,
  re-checks the requesting actor's authorization, and fails closed on timeout,
  error, missing data, or drift.
- Persist an immutable, secret-free reviewed launch snapshot and matching digest
  on each approved binding version. The current binding retains only a digest,
  which is insufficient to compare all execution-relevant live fields.
- Persist independent, secret-free preflight evidence linked to the durable
  read-only agent command before any operation/execution exists, then copy its
  identifiers and digests into the immutable launch snapshot.
- Bind the reviewed revision, live snapshot digest, and durable command-result
  digests into the immutable launch snapshot. Only then may the system persist
  the execution and dispatch `awx.launch_job`.
- Require the AWX execution principal to remain least-privilege: read the
  reviewed resources and execute only the approved templates; users do not
  receive an AWX credential or a path to bypass ServiceRadar authorization.
- Add fixtures, adversarial drift tests, operator-safe error surfaces, and a
  runbook for reviewing/re-enabling a changed binding.

## Impact

- Affected specs: `ansible-automation`
- Affected code: AWX WASM plugin, automation secure-launch resolver/launcher,
  agent-command result projection, callback-binding review model, tests, and
  operational documentation.
- This is a security gate for mutable AWX execution. It does not enable the
  currently disabled demo callback policy until the implementation and live
  verification are complete.
