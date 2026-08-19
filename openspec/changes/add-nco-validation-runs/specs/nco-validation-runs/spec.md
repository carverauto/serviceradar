# nco-validation-runs

## ADDED Requirements

### Requirement: Validation Run Create

The system SHALL accept an authenticated request that names an enabled
composite check and one or more device targets identified by IP address
and partition, optionally corroborated by MAC, and SHALL create a
validation run that returns immediately with a run identifier and the
canonical device UID for every target.

The request SHALL accept either a `devices` array of
`{ip, partition?, mac?}` objects or a single-device shorthand of top-level
`ip`, optional `mac`, and optional `partition`. A missing partition SHALL
default to `"default"`. A top-level partition SHALL apply to every device
that does not set its own.

The system SHALL reject the request and create no run when any target
fails identity resolution, when the check slug is unknown or not
`enabled`, when the target list is empty, or when the target count
exceeds 128.

The create response SHALL be `202 Accepted` and SHALL include the run
`id`, the run `status`, the check slug, and each target's `ip`,
`partition`, and resolved `uid`. Identity resolution SHALL complete
before the response is written. Probe dispatch and composite evaluation
SHALL happen after the response.

#### Scenario: Single-device shorthand returns uid and run id

- **GIVEN** an enabled composite check with slug `farm01-lab-isolation`
- **AND** a live device whose IP is `192.168.1.55` in partition `default`
  with uid `sr:8cad4cc3-e9f8-4873-a1fe-cf2529b246a0`
- **WHEN** a principal with `validation_runs.execute` POSTs
  `{"check":"farm01-lab-isolation","partition":"default","ip":"192.168.1.55"}`
- **THEN** the response SHALL be 202
- **AND** the body SHALL contain a run `id`
- **AND** the body SHALL contain
  `devices[0].uid = "sr:8cad4cc3-e9f8-4873-a1fe-cf2529b246a0"`
- **AND** no sweep group `run_now` SHALL have been invoked

#### Scenario: Device list is accepted

- **WHEN** the request body supplies `devices` with two distinct IPs in
  partition `default`
- **AND** both resolve uniquely
- **THEN** the 202 body SHALL list both resolved uids
- **AND** one validation run SHALL cover both devices

#### Scenario: Unknown IP creates no run

- **WHEN** the request names an IP that matches no live device in the
  given partition
- **THEN** the response SHALL be 404
- **AND** no validation run SHALL be created
- **AND** no device SHALL be created

#### Scenario: Ambiguous IP is rejected

- **WHEN** the request names an IP that resolves to more than one live
  device in the given partition
- **THEN** the response SHALL be 409
- **AND** the body SHALL name the candidate uids
- **AND** no validation run SHALL be created

#### Scenario: Conflicting MAC is rejected

- **GIVEN** IP `192.168.1.55` resolves to device A
- **AND** MAC `aa:bb:cc:dd:ee:ff` resolves to device B
- **WHEN** the request supplies both
- **THEN** the response SHALL be 409 with error `mac_ip_conflict`
- **AND** no validation run SHALL be created

#### Scenario: Missing MAC is ignored

- **GIVEN** IP `192.168.1.55` resolves to device A
- **AND** no inventory record carries MAC `aa:bb:cc:dd:ee:ff`
- **WHEN** the request supplies that IP and MAC
- **THEN** the run SHALL be created for device A
- **AND** the MAC SHALL NOT fail the request

#### Scenario: Draft or disabled check is rejected

- **WHEN** the request names a composite check that is not `enabled`
- **THEN** the response SHALL be 400
- **AND** no validation run SHALL be created

#### Scenario: Unauthorized principal is rejected

- **GIVEN** a principal lacking `validation_runs.execute`
- **WHEN** it POSTs a validation run
- **THEN** the response SHALL be 403
- **AND** no run SHALL be created

### Requirement: IP-Authoritative Identity

The system SHALL resolve each validation-run target using the IP address
as the authoritative locator and the partition as the identity scope.

A supplied MAC SHALL corroborate the IP resolution and SHALL NOT replace
it. A MAC that is absent from inventory SHALL be ignored. A MAC that
resolves to a different live device than the IP SHALL be a conflict.

The resolver SHALL consult partition-scoped `device_identifiers` of type
`ip` first and SHALL fall back to the unique live `ocsf_devices.ip` row
when no identifier hit exists. The resolver SHALL NOT mint a new `sr:`
UID.

#### Scenario: Identifier in partition wins

- **GIVEN** `device_identifiers` has `(ip, 10.0.0.5, site-b)` bound to
  uid `sr:aaa`
- **WHEN** a validation run target is `{ip: "10.0.0.5", partition: "site-b"}`
- **THEN** the resolved uid SHALL be `sr:aaa`

#### Scenario: Live device row is the fallback

- **GIVEN** no `device_identifiers` row for IP `192.168.1.55`
- **AND** exactly one live `ocsf_devices` row with that IP
- **WHEN** a validation run target uses that IP and partition `default`
- **THEN** the resolved uid SHALL be that row's uid

### Requirement: Targeted Vantage-Point Re-probe

After a validation run is created, the system SHALL, for each resolved
device and each `vantage_point` agent on the named composite check,
select the enabled sweep groups in that agent's partition that already
cover the device, and SHALL dispatch a targeted scan using those
groups' compiled scan settings.

A sweep group covers a device when the device IP is in the group's
`static_targets` (exact or CIDR) or when the group's `target_query`
SRQL, constrained to `uid:<resolved_uid>`, returns that device.

Compiled settings SHALL be the same merge the sweep compiler already
applies: the group's sweep profile (`modes`, `ports`, `timeout`,
concurrency, ICMP/TCP settings) as the base, group-level overrides on
top. The system MUST NOT invent a probe mode or port list that no
covering group uses.

The probe target list SHALL be exactly the run's resolved IPs that the
agent covers. The system MUST NOT invoke sweep-group `run_now` and MUST
NOT expand the check's `scope_query` into additional targets.

When a device matches no covering group for a vantage agent, that
vantage SHALL be recorded as `uncovered` and SHALL NOT be probed.

Probe results for the run SHALL be written into
`device_agent_availability` for `{device_uid, agent_id}` so the
composite check's existing vantage-point resolver can read them.
A generic ad-hoc scan that is not part of a validation run SHALL NOT
gain this availability write.

#### Scenario: Farm isolation replays farm-scan from both vantage groups

- **GIVEN** check `farm01-lab-isolation` has vantage points
  `agent-alma-test01` and `k8s-agent`
- **AND** `farm01-sweep-open` is assigned to `agent-alma-test01` with
  `target_query` `in:devices` and profile `farm-scan`
  (modes `icmp,tcp,arp`, ports 22/80/443/8080)
- **AND** `farm01-sweep-isolated` is assigned to `k8s-agent` with the
  same query and profile
- **AND** a run targeting `192.168.1.55`, which matches `in:devices`
- **WHEN** the orchestrator dispatches
- **THEN** each of those two agents SHALL receive a targeted scan whose
  only address is `192.168.1.55`
- **AND** each scan SHALL use `farm-scan`'s compiled modes and ports
- **AND** no sweep group `run_now` SHALL be invoked
- **AND** the run SHALL record the covering `sweep_group_id` and
  `profile_id` on each device/vantage row

#### Scenario: Device outside a group's SRQL is not probed with a made-up profile

- **GIVEN** a vantage agent's only sweep group has
  `target_query` `in:devices ip:10.0.0.0/8`
- **AND** the run's device IP is `192.168.1.55`
- **WHEN** the orchestrator selects covering groups
- **THEN** that vantage SHALL be `uncovered` for the device
- **AND** no ICMP (or any other) probe SHALL be dispatched to that agent
  for that IP

#### Scenario: Group port override beats the profile

- **GIVEN** a covering group whose profile ports are `[22, 80, 443, 8080]`
- **AND** the group overrides `ports` to `[443]`
- **WHEN** the orchestrator compiles settings
- **THEN** the dispatched scan SHALL use ports `[443]`
- **AND** SHALL NOT add 22, 80, or 8080

#### Scenario: Availability is updated from the targeted probe

- **GIVEN** Alma reports the host available and k8s reports it blocked
- **WHEN** those probe results persist
- **THEN** `device_agent_availability` for that uid and
  `agent-alma-test01` SHALL show available with a fresh `checked_at`
- **AND** the row for `k8s-agent` SHALL show unavailable with a fresh
  `checked_at`

### Requirement: Subset Composite Evaluation

Once vantage-point availability for a run is fresh, the system SHALL
evaluate the named composite check for only the run's device UIDs,
reading device metadata (including facts such as `acl_enforced`) at
evaluation time.

The system SHALL upsert `device_composite_check_results` for those
`{device_uid, check_id}` pairs and SHALL copy `verdict`, `status`,
`inputs`, and `evaluated_at` onto the run's device rows.

The composite check definition SHALL remain a derivation: it SHALL NOT
itself dispatch probes. The validation run is the orchestrator.

#### Scenario: Fact written after POST is visible at evaluate

- **GIVEN** a run created for `192.168.1.55`
- **AND** NCO PATCHes `acl_enforced=true` on the returned uid before
  probes finish
- **WHEN** the run evaluates
- **THEN** the verdict snapshot SHALL use `acl_enforced=true`

#### Scenario: Official result table matches the run

- **WHEN** a run completes with verdict `isolated_verified` for a device
- **THEN** `device_composite_check_results` for that device and check
  SHALL also read `isolated_verified`
- **AND** `in:composite_results check:farm01-lab-isolation` SHALL return
  the same verdict

### Requirement: Pollable Run Status

The system SHALL expose `GET /api/v1/validation-runs/:id` and
`GET /api/v1/validation-runs/:id/results` to a principal holding
`validation_runs.read`.

A run SHALL progress through `pending`, `probing`, `evaluating`, and
then `completed`, `failed`, or `timed_out`. The GET payload SHALL
include per-device `ip`, `partition`, `uid`, `verdict`, `status`,
`inputs`, `evaluated_at`, and `error`.

The system SHALL NOT require a caller-supplied webhook or callback URL.
A run that exceeds its deadline (default 180 seconds) SHALL mark
unfinished devices `timed_out` on the run and SHALL NOT write a passing
verdict to `device_composite_check_results` for those devices.

#### Scenario: Poll until completed

- **GIVEN** a run whose probes and evaluation have finished
- **WHEN** NCO GETs `/api/v1/validation-runs/:id`
- **THEN** `status` SHALL be `completed`
- **AND** each device row SHALL include `uid`, `verdict`, `status`, and
  `inputs`

#### Scenario: Deadline does not invent a pass

- **GIVEN** a run whose k8s vantage probe has not returned by the
  deadline
- **WHEN** the deadline fires
- **THEN** that device's run row SHALL be `timed_out`
- **AND** `device_composite_check_results` SHALL NOT be upserted to
  `isolated_verified` for that device as a result of the timeout
