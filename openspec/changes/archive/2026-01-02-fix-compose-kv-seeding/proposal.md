# Change: Fix Docker Compose KV seeding

## Why
- Docker Compose services start with `CONFIG_SOURCE=file`, so KV managers never initialize; the datasvc bucket only holds poller entries and watcher telemetry exposes poller alone while agent/core appear down in the UI.
- Kubernetes deployments run with `CONFIG_SOURCE=kv`, so Compose diverges from the documented KV seeding behavior and leaves the `kv-configuration` Automatic Configuration Seeding requirement unmet for local stacks.

## What Changes
- Run Compose services with KV-backed configuration (set `CONFIG_SOURCE=kv` plus `KV_*` env) so bootstrap writes defaults into datasvc and publishes watcher snapshots (including poller/agent/core/zen/sync/mapper/db-event-writer).
- Ensure Compose variants seed poller/agent/core templates on first boot without clobbering existing KV data and ship a stable zen consumer that doesn’t restart-loop on initial KV watch.
- Bundle the serviceradar-tools image with a Compose-friendly NATS context so JetStream/KV can be inspected locally without pulling extra images.
- Document/verify the expected KV keys and watcher telemetry for the Compose stack, and validate clean bring-up seeding in datasvc.

## Impact
- Affected specs: kv-configuration
- Affected code: docker-compose*.yml (including poller-stack variants), docker/compose templates, docs/docs/docker-setup.md
