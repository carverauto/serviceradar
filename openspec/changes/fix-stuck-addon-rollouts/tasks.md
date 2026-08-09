## 1. Establish the current state as fixtures

- [ ] 1.1 Capture the demo fleet's paused rollouts, observed versions, and
      `addon_statuses.degradation_reason` strings as test fixtures, so every
      case below is driven by a real reported status rather than an invented one
- [ ] 1.2 Add a regression fixture for each distinct reason string currently in
      the fleet: `no PowerDNS Recursor protobuf producer connected`,
      `resource limits not enforced ... need cpu,memory,pids`,
      `systemd unit failed`, `dial netprobe socket: connection refused`

## 2. Health-gate classification

- [ ] 2.1 Introduce a classifier over a reported add-on status that returns
      candidate fault, environment fault, or healthy, derived from the status
      itself rather than a per-add-on allowlist
- [ ] 2.2 Treat not-running, unit-failed, crash-looping, and control-interface-
      unreachable as candidate faults
- [ ] 2.3 Treat running-with-missing-external-dependency and running-with-
      unenforceable-host-resource-policy as environment faults
- [ ] 2.4 Gate rollout pausing on candidate faults only; record environment
      faults on the rollout as advisories
- [ ] 2.5 Unit-test the classifier against every fixture from 1.2, asserting
      powerdns and anomaly do not block while bumblebee and netprobe do

## 3. Blocked-rollout evidence

- [ ] 3.1 Record agent identifier, reported reason, and evidence age whenever a
      rollout pauses on health
- [ ] 3.2 Make pausing on health impossible without that evidence, and cover it
      with a test that fails if a pause path omits any of the three
- [ ] 3.3 Backfill evidence for the currently paused rollouts where the
      underlying status rows still exist; leave the reason blank rather than
      guessing where they do not

## 4. Superseded-rollout reaping

- [ ] 4.1 Add a supersession check that resolves a rollout when every in-scope
      target's observed version already equals or exceeds the candidate version
- [ ] 4.2 Drive it from observed fleet state so convergence outside the rollout
      counts
- [ ] 4.3 Make superseded terminal: no resume, roll back, or cancel
- [ ] 4.4 Run it during normal rollout evaluation, not as a one-off cleanup
- [ ] 4.5 Test partial convergence is left alone (scalibr at 0.1.2 against a
      0.1.3 candidate must not be reaped)
- [ ] 4.6 Test a fleet that has moved past the candidate (workload-identity on
      0.1.7 against a 0.1.5 candidate) reaps without rolling anything back

## 5. Version truthfulness

- [ ] 5.1 Treat a placeholder version report as unknown rather than as a version
- [ ] 5.2 Exclude unknown-version add-ons from update-state derivation instead
      of computing them as maximally behind
- [ ] 5.3 Investigate why `otel-collector` reports `0.0.0` and fix it at the
      source if it is the add-on rather than the reporting path

## 6. Fleet view

- [ ] 6.1 Aggregate the rollout list to one row per `(add-on, candidate version)`
      with combined progress
- [ ] 6.2 Make per-scope records inspectable by expanding the row
- [ ] 6.3 Default the list to outstanding rollouts; move terminal ones to an
      explicit history view
- [ ] 6.4 Show only actions that can change the row's state
- [ ] 6.5 Show reason, agent, and evidence age on every non-healthy row, and
      mark advisory faults as advisory
- [ ] 6.6 Confirm this satisfies `add-native-addon-fleet-rollouts` task 6.6 and
      note it there rather than implementing it twice

## 7. Verification

- [ ] 7.1 Unit coverage for classification, evidence recording, supersession,
      and version handling
- [ ] 7.2 LiveView coverage for aggregation, outstanding-versus-history, action
      availability, and reason visibility
- [ ] 7.3 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core`
      and `--project elixir/web-ng --phoenix`
- [ ] 7.4 Verify against the demo fleet: the four superseded rollouts resolve,
      powerdns and anomaly stop pausing on environment faults, and bumblebee on
      sr-test-pve04 and netprobe on ns01 still block with named evidence
- [ ] 7.5 Publish before/after counts of outstanding rollouts and paused
      rollouts from the demo fleet
