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

- [ ] 2.1 Add `agent-self-report` to `SourcePolicy` as a first-party source: NOT in
  `observer_agent_source?/1`, so `include_agent_identifier?/2` admits its `agent_id`.
- [ ] 2.2 Confirm by test that no EXISTING source changes classification. `observer_agent_source?/1`
  has `enrichment_only_source?/1` as a disjunct, so edits there reach further than they read.
- [ ] 2.3 Assert the source may create — it must not be swept into the enrichment-only set, which
  is the rule that forbids creation.

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

- [ ] 7.1 `inventory/discovery/decoders/process.ex` justifies `:enrichment_only` on the grounds
  that "sysmon and the agent's own self-report create" the agent host's device. That is currently
  false on farm01. Once this change ships it becomes true; until then, correct the comment rather
  than leaving a claim the data contradicts.
- [ ] 7.2 `openspec validate add-agent-self-report-device-identity --strict`
