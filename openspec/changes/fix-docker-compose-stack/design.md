## Context
The Docker Compose stack is the primary on-ramp for OSS users and local testing. Today, multiple services crash or remain unhealthy due to migration conflicts, missing Oban schema, duplicate ProcessRegistry startup, and NATS/JetStream auth or subject configuration issues. These failures require manual intervention and obscure the intended single-deployment architecture.

## Goals / Non-Goals
- Goals:
  - `docker compose up -d` on a clean checkout brings the stack to healthy without manual steps.
  - Migrations are idempotent or serialized; repeated boots never fail on duplicate objects.
  - Oban schema is provisioned automatically so job processing is stable.
  - NATS JWT usage is consistent across all services; Zen stream updates succeed.
- Non-Goals:
  - Changing production Helm workflows beyond what is required to keep parity.
  - Introducing new multi-tenant behavior or control-plane responsibilities.

## Decisions
- Decision: Make the consolidated Ash migration idempotent and include Oban schema.
  - Why: Compose must tolerate restarts and multiple nodes; Oban tables are required for peers/pruner.
- Decision: Enforce a single migration runner (core-elx) in compose and remove web-ng `mix ecto.migrate`.
  - Why: Avoid concurrent migrations and duplicate table creation.
- Decision: Single source of truth for overlapping tables (CNPG SQL vs Ash).
  - Why: Duplicate creation causes hard failures; ownership must be explicit.
- Decision: Gate ProcessRegistry startup in dependency releases via configuration.
  - Why: Avoid Horde supervisor name collisions within a single VM.

## Risks / Trade-offs
- Converting a large migration file to idempotent operations is error-prone.
  - Mitigation: Incrementally adjust and validate with clean compose boots.
- Removing web-ng migrations may delay schema updates if core-elx is not running.
  - Mitigation: Compose ensures core-elx is required; document startup ordering.

## Migration Plan
1. Add Oban tables and idempotent guards to the consolidated Ash migration.
2. Remove duplicate table definitions from CNPG SQL or mark Ash resources as `migrate? false`.
3. Update web-ng container startup to avoid `mix ecto.migrate`.
4. Add compose env/config flags to prevent ProcessRegistry double start.
5. Validate with clean docker volumes and log-based health checks.

## Open Questions
- Should Oban tables live in Ash migration or remain as a dedicated raw SQL block within the same file?
- Which side owns `checkers` and other overlapping tables: CNPG SQL or Ash?
