## 1. Warehouse table and ingest
- [ ] 1.1 Add `priv/starrocks/00NN_flow_process_attribution_observations.sql`: Duplicate Key, hourly `date_trunc` partitions, `partition_live_number` per design, columns covering the current observation payload; register it with the schema migrator.
- [ ] 1.2 Publish admitted `FlowAttributionEvent` batches from `StatusHandler` to `flows.attribution.observations` (flow demand domain) instead of calling `FlowAttribution.persist/4`; keep bounded admission.
- [ ] 1.3 Add the EventWriter processor and stream/consumer config that Stream-Loads observations into the new table; grant the NATS publish/subscribe permissions in the Helm chart.
- [ ] 1.4 Tests: publisher emits the subject with the expected payload; processor maps rows to the table columns; admission stays bounded.

## 2. In-warehouse correlation
- [ ] 2.1 Replace `warehouse_correlation_sql` with one StarRocks statement joining recent unattributed flows to live observation partitions, preserving every candidate family and precedence rank from *Correlation Is Protocol-Aware And Exact-First*.
- [ ] 2.2 Pass agent node IPs and public endpoint backends read from CNPG as bound parameters.
- [ ] 2.3 Enrich matched rows with workload identity by `(agent_id, container_id)` from CNPG for the stamped batch only.
- [ ] 2.4 Keep publishing stamps on `events.flow.attribution` with `flow_attribution_update_version`; `FlowAttributionUpdates` unchanged.
- [ ] 2.5 Tests at the correlation boundary: one case per precedence rank, newest-wins within a rank, relaxed-UDP ambiguity, ICMP without port equality, node-SNAT, public endpoint ordering, and a flow outside the window staying unattributed.

## 3. Delete the CNPG path
- [ ] 3.1 Remove `Persistence.insert_current_rows/1`, `Retention`, `WorkloadBackfill`, and the CNPG correlation SQL and lock.
- [ ] 3.2 Migration dropping `platform.flow_process_attribution_current` and its indexes.
- [ ] 3.3 Without StarRocks: publisher and correlator do not run; health reports `attribution_disabled: starrocks_required`. Test it.
- [ ] 3.4 Grep the workspace (web-ng, SRQL, docs, Helm) for remaining references and remove them.

## 4. Observability
- [ ] 4.1 Emit correlator pass duration, flows read, matches by strategy, stamped count, observation lag, ingest rate and live partition count as metrics through JetStream.

## 5. Load-test gate
- [ ] 5.1 Replay demo-scale observation and flow rates against a warehouse for several hours.
- [ ] 5.2 Gate: correlation p95 well under the pass interval, zero failed passes, observation table size flat at steady state (bounded by live partitions), attribution coverage no worse than the CNPG path.
- [ ] 5.3 Record the numbers in the PR.

## 6. Cutover
- [ ] 6.1 Ship in one release; verify on demo that observations land, passes succeed and flows are stamped.
