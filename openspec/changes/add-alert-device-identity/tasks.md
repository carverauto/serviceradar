# Tasks

## 1. Mechanism
- [x] 1.1 Add a `:device_uid` option to `AlertGenerator.from_event/2` and write it into attrs
- [x] 1.2 Make `normalize_device_uid/1` public, rejecting non-binaries and empty/whitespace strings
- [x] 1.3 Document the FK contract on `from_event/2` — a bad uid loses the alert, it does not mislabel it

## 2. Stateful engine call site
- [x] 2.1 Build a correlation candidate from the record's `device_uid` / `agent_id` / `partition`
- [x] 2.2 Resolve it through `DeviceCorrelation.resolve/1` and pass the canonical result
- [x] 2.3 Skip the resolver entirely when the record carries no identity at all
- [x] 2.4 Never pass a raw record field through
- [x] 2.5 Confirm the resolved uid exists in inventory before writing it — `resolve/1` returns an `sr:`-prefixed input verbatim when the merge-chain follow finds nothing, so it alone does not guarantee an FK-valid value

## 3. Tests
- [x] 3.1 `normalize_device_uid/1` accepts a real uid, trims, and rejects "" / whitespace / non-binaries
- [x] 3.2 Structural: `:trigger` still accepts `device_uid`, so the change cannot become inert
- [x] 3.3 Structural: the attribute stays public so the suppression gate can read it off the changeset
- [x] 3.5 Pin the resolver's actual contract, so the existence check cannot be dropped as redundant
- [ ] 3.4 Integration: an alert for an out-of-service device is suppressed — needs a seeded device and is better placed with the existing DB-backed alert tests

## 4. Verification
- [x] 4.1 `mix compile` clean
- [x] 4.2 New tests pass
- [x] 4.3 `mix credo --strict` on both touched files — no issues; no `authorize?: false` introduced, the resolver supplies its own SystemActor
- [x] 4.4 `openspec validate add-alert-device-identity --strict`

## 5. Follow-ups (not this change)
- [ ] 5.1 Trivy and log-promotion callers — both need a resolved uid threaded through their insert paths
- [ ] 5.2 Index on `(device_uid, triggered_at DESC)` once a device-scoped query ships
- [ ] 5.3 `stats:` on the alerts entity returns un-aggregated rows with a 200 — pre-existing, orthogonal
- [ ] 5.4 Audit existing notification routes and out-of-service markings before deploy
