## 1. Diagnostics and guardrails
- [ ] 1.1 Add structured logging/metrics that tag AGE errors (XX000 TM_Updated vs 57014 statement_timeout) with batch sizes and queue depth.
- [ ] 1.2 Surface configuration for AGE statement timeout/worker limits (env/config) with sane defaults for demo.

## 2. Serialized and retried writer
- [ ] 2.1 Introduce a bounded work queue/worker that serializes AGE graph/interface/topology writes and applies chunk size limits.
- [ ] 2.2 Add retry/backoff for transient AGE errors (`Entity failed to be updated` XX000 and statement_timeout) with capped attempts and jitter.
- [ ] 2.3 Expose queue depth/backlog metrics/alerts and keep registry logs from spamming while still surfacing hard failures.

## 3. Backfill coexistence and validation
- [ ] 3.1 Route age-backfill through the same queue or add coordination (mutex/flag) so rebuilds cannot run concurrent MERGEs against live ingestion.
- [ ] 3.2 Validate on demo: run age-backfill while pollers/agents publish updates; confirm no AGE XX000/statement timeout warnings and graph data persists.
- [ ] 3.3 Update the AGE runbook with contention troubleshooting and verification steps.
