# Change: Add NetFlow Zen rule bootstrap for deployments

## Why
NetFlow ingestion depends on Zen rules that transform raw flow records into OCSF events. Today the rule seeding path relies on
core-elx reconciliation against datasvc KV, which is skipped when datasvc is unavailable. That leaves NetFlow flows in NATS
unprocessed and the db-event-writer idle. We need deterministic, deployment-time rule seeding so NetFlow works immediately
after install without manual intervention.

## What Changes
- Add deployment-time `zen-put-rule` bootstrap for the NetFlow rule bundle when NetFlow ingestion is enabled (Helm, k8s
  manifests, and Docker Compose).
- Ensure the NetFlow rule bundle ships with the NetFlow collector artifacts so bootstrap jobs can find the rule file.
- Make rule seeding idempotent, retry on transient failures, and surface errors when retries are exhausted.

## Impact
- Affected specs: `observability-rule-management`, `docker-compose-stack`
- Affected code: Helm chart, k8s manifests, Docker Compose stack, NetFlow rule asset packaging, zen rule bootstrap tooling
