# Tasks

## 1. Establish the evidence as a regression test

- [ ] 1.1 DB-backed test reproducing the farm01 shape BEFORE changing behaviour: a device created
  by an observer source at address A, an agent self-report arriving for the same host at address
  B, and the assertion that two devices exist. It must FAIL after the change, which is what makes
  it the proof.
- [ ] 1.2 Register the new test source in `test/INTEGRATION_SOURCE_DISPOSITIONS.tsv` and project
  it into `build/integration_test_dispositions.bzl`, or add it to an existing registered source
  with the same disposition and update that source's selected-test count. There is no generator;
  `//:ci_heavy_gate_contract_test`, `//build:integration_selection_equivalence_test` and
  `//build:integration_shards_topology_test` all enforce the projection.

## 2. Classify the source

- [x] 2.1 **DONE.** `SourcePolicy.agent_self_report_source/0` and `agent_self_report_source?/1`
  name the source explicitly. Note what the code turned out to be: `observer_agent_source?/1` is a
  POSITIVE list, so a new source is first-party by DEFAULT and no edit was needed to admit it. The
  value added is that the intent is now visible and the properties it depends on are pinned by
  tests -- nothing would have failed loudly if someone later swept it into
  `enrichment_only_source?/1`, which is a disjunct of `observer_agent_source?/1` and would silently
  strip both anchoring AND creation.
- [x] 2.2 **DONE.** `source_policy_self_report_test.exs` asserts every previously-observer source
  is still an observer and still refused an `agent_id`, and that every enrichment-only source and
  `identity_source` is unchanged.
- [x] 2.3 **DONE.** Asserted directly, plus the sharper case: a self-report carrying an
  `identity_source` in its metadata still is not demoted, since `enrichment_only_source?/1` keys on
  that field as well as on `source`.

## 3. Produce the self-report

- [ ] 3.1 Identify where an agent `PushStatus`/Hello reaches inventory today, and emit one
  self-report device update per cycle from it.
- [ ] 3.2 Source the address from the agent's re-detected value, NOT from `config.HostIP`. The
  same trap was just fixed for netprobe's `collector_ip` (PR #4004): `host_ip` in `agent.json` is
  an onboard-time pin that a re-IP'd host leaves stale, and every other outbound path already
  uses `getSourceIP()`.
- [ ] 3.3 Enforce the single-subject boundary at the producer and reject a multi-subject
  self-report rather than partially applying it.

## 4. Resolve and anchor

- [ ] 4.1 Resolve by `agent_id` first; on a hit, update the device's `ip`.
- [ ] 4.2 On a miss, resolve by address so a self-report lands on an observer-created device
  instead of duplicating it, then register `agent_id` there.
- [ ] 4.3 Create only when both miss.
- [ ] 4.4 Register `agent_id` as a strong identifier on the resolved device.
- [ ] 4.5 If the agent reports its own MAC, register it under the existing rules — a
  locally-administered or randomized MAC must not anchor (`census_anchorable_mac?/1`).

## 5. Guard the boundary

- [ ] 5.1 Test: a forwarded observation about another host keeps its observer source and does not
  register the forwarding agent's `agent_id` on that host.
- [ ] 5.2 Test: two hosts reported through one agent stay two devices — the collector over-merge
  assertion, run against the new source.
- [ ] 5.3 Test: `agent_id` rotation yields two devices and is not merged on address alone.

## 6. Verify against the real failure

- [ ] 6.1 Re-run the 1.1 test and confirm it now fails to reproduce the duplicate.
- [ ] 6.2 On a lab host, change the address and confirm at ingest — not after a sweep — that the
  device's `ip` moved and no second device appeared. Gate on the artefact: query for the device
  rows after the change, and confirm the run postdates the rollout.
- [ ] 6.3 Confirm `merge_audit` records NO new merge for that host, since the point is that no
  duplicate was created.

## 7. Close the documentation gap

- [x] 7.1 **DONE.** Comment corrected, with the measurement that contradicts it recorded inline:
  only 15 devices out of 50,212 on the demo cluster carry an `agent_id` identifier at all, and the
  agent host's device is minted by OBSERVER sources. The note points at this change and says to
  delete itself once the claim becomes true.
- [ ] 7.2 `openspec validate add-agent-self-report-device-identity --strict`
