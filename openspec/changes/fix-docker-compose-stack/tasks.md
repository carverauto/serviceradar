# Tasks: Stabilize Docker Compose Stack

## 1. Migration + Schema Ownership
- [ ] 1.1 Add Oban tables (`oban_jobs`, `oban_peers`, etc.) to `20260117090000_rebuild_schema.exs` (or an idempotent equivalent).
- [ ] 1.2 Make Ash migration idempotent (use `create_if_not_exists`/`execute` guards) or serialize startup migrations so repeated runs never fail.
- [ ] 1.3 Remove duplicate table ownership between CNPG SQL and Ash migrations (e.g., `checkers`), or mark one side as `migrate? false` with raw SQL as the single source.
- [ ] 1.4 Verify `core-elx` is the only service running Ash migrations in compose.

## 2. Release Startup Behavior
- [ ] 2.1 Remove `mix ecto.migrate` from web-ng container startup and rely on core-elx migrations.
- [ ] 2.2 Ensure `serviceradar_core` does not start ProcessRegistry twice when embedded in web-ng/agent-gateway releases.
- [ ] 2.3 Confirm Oban starts cleanly in web-ng with `SERVICERADAR_WEB_NG_OBAN_ENABLED=true` once schema exists.

## 3. NATS + JetStream Stability
- [ ] 3.1 Audit all compose services for NATS JWT usage; enforce creds in templates/config.
- [ ] 3.2 Fix zen JetStream subject overlap error (no-ack requirements or subject patterns) and ensure initial rule seeding succeeds.
- [ ] 3.3 Ensure NATS account permissions cover stream/consumer operations needed by zen and db-event-writer.

## 4. Compose Health + Documentation
- [ ] 4.1 Update health checks/dependencies so caddy/web-ng report healthy only after core dependencies are ready.
- [ ] 4.2 Add a documented, idempotent `docker compose up -d` smoke test flow in docs.
- [ ] 4.3 Validate: clean volumes -> `docker compose up -d` -> all services healthy without manual steps.
