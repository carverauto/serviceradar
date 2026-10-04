## 1. Control-plane binding

- [ ] 1.1 Add a migration and resource for globally unique Kubernetes `cluster_id` ownership by enrolled `agent_id` and `partition_id`, with restrictive references and audit fields.
- [ ] 1.2 Add administrator-only create, transfer, read, and guarded-delete actions with a navigable management surface.
- [ ] 1.3 Include binding usage in agent deletion and replacement checks so an active owner cannot disappear silently.

## 2. Gateway provenance

- [ ] 2.1 Make the agent-path marker and authenticated agent/partition header contract explicit and reject incomplete provenance before publish.
- [ ] 2.2 Add focused gateway tests proving body identity fields cannot replace authenticated connection provenance.

## 3. EventWriter enforcement

- [ ] 3.1 Classify agent-forwarded and direct publisher messages without allowing malformed agent provenance to fall back to direct mode.
- [ ] 3.2 Lock and verify the cluster binding in the same transaction as snapshot upsert and soft deletion.
- [ ] 3.3 Persist authenticated agent/partition provenance and emit bounded rejection telemetry without logging snapshot contents.
- [ ] 3.4 Ensure rejected, unbound, and concurrently transferred snapshots perform no insert, update, resurrection, or soft deletion.

## 4. Operator workflow and documentation

- [ ] 4.1 Document binding creation and agent replacement for the remote inventory installation path.
- [ ] 4.2 Surface actionable health/status information when inventory is rejected because its binding is absent or mismatched.
- [ ] 4.3 Document that direct in-cluster publisher authorization remains governed by its platform NATS credential.

## 5. Validation

- [ ] 5.1 Add focused unit coverage for provenance parsing, exact binding matches, mismatches, missing bindings, and malformed agent-path headers.
- [ ] 5.2 Add database regression coverage proving a mismatched enrolled agent cannot alter or delete another synthetic cluster's rows.
- [ ] 5.3 Add transfer coverage proving the old agent loses authority atomically and the replacement gains it.
- [ ] 5.4 Run the affected remote CI targets and the no-mistakes pipeline; inspect BuildBuddy invocations with `bb view <invocationId>` from the primary checkout.
- [ ] 5.5 Validate one authorized and one rejected synthetic snapshot through the supported remote path after rollout, with explicit failure branches and post-run row queries.
