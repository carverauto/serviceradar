# Change: Stabilize Docker Compose stack startup

## Why
`docker compose up -d` is currently not self-booting: multiple services crash or remain unhealthy (web-ng, agent-gateway, zen, caddy) due to missing Oban schema, duplicate table creation between CNPG SQL and Ash migrations, ProcessRegistry double-start conflicts, and NATS JWT/JetStream errors. New users should be able to clone the repo and bring the stack up without manual intervention.

## What Changes
- Add Oban schema to the consolidated Ash migration so `oban_jobs`/`oban_peers` exist on first boot.
- Make the consolidated Ash migration idempotent and safe to re-run (or serialize it) so repeated boots do not fail on duplicate tables/indexes.
- Eliminate duplicate table ownership between CNPG SQL migrations and Ash migrations (e.g., `checkers`).
- Ensure only one migration runner executes in Docker Compose and remove web-ng's `mix ecto.migrate` startup.
- Resolve ProcessRegistry double-start conflicts when serviceradar_core is a dependency of web-ng/agent-gateway.
- Ensure all NATS clients use JWT creds in compose and fix zen JetStream subject/consumer config so it can extend the `events` stream and seed rules.
- Update compose health checks/dependencies and docs to reflect the stable boot sequence.

## Impact
- Affected specs: docker-compose-stack (new), cnpg, job-scheduling, ash-cluster, kv-configuration
- Affected code: Docker compose stack, core-elx migrations, web-ng release startup, NATS/Zen config
