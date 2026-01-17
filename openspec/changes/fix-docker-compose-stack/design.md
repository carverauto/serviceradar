# Design: Fix Docker Compose Stack

## Context

The Docker Compose development stack has multiple services that form a distributed Erlang cluster (core-elx, web-ng, agent-gateway). These services use Horde for distributed process management. The current configuration has race conditions that cause services to fail when starting simultaneously.

## Goals / Non-Goals

**Goals:**
- All services start and reach healthy state
- Clean startup after `docker compose down -v && docker compose up -d`
- No crash loops or restart cycles
- Local development stack is usable

**Non-Goals:**
- Production/Kubernetes deployment changes (out of scope)
- Performance optimization
- Adding new features

## Decisions

### Decision 1: Sequential Cluster Startup via depends_on

**What:** Make web-ng and agent-gateway explicitly depend on core-elx being healthy before starting.

**Why:** Horde's distributed supervision requires a stable primary node. When multiple nodes start simultaneously and race to register the same named supervisors, the later nodes fail with "already started" errors.

**Implementation:**
```yaml
web-ng:
  depends_on:
    core-elx:
      condition: service_healthy
    # ... other dependencies

agent-gateway:
  depends_on:
    core-elx:
      condition: service_healthy
    # ... other dependencies
```

### Decision 2: Add Missing Health Checks

**What:** Add healthcheck to db-event-writer and zen services.

**Why:** Services without health checks can't be used as dependencies with `condition: service_healthy`. Also makes monitoring easier.

**Implementation:**
```yaml
db-event-writer:
  healthcheck:
    test: ["CMD-SHELL", "wait-for-port --host 127.0.0.1 --port 50041 --attempts 1 --interval 1s --quiet"]
    interval: 30s
    timeout: 5s
    retries: 5
    start_period: 20s

zen:
  healthcheck:
    test: ["CMD-SHELL", "wait-for-port --host 127.0.0.1 --port 50040 --attempts 1 --interval 1s --quiet"]
    interval: 30s
    timeout: 5s
    retries: 5
    start_period: 30s
```

### Decision 3: Fix zen JetStream Configuration

**What:** The zen service was failing because its stream subjects used invalid wildcard patterns that overlapped with JetStream API requirements.

**Why:** Previous changes had incorrectly added wildcard prefixes to zen's subjects (e.g., `*.logs.syslog` and `*.logs.internal.>`). These patterns conflicted with NATS JetStream's subject handling and caused error 10052.

**Solution:** Remove all wildcard prefixes from zen's subject configuration:
- `*.logs.syslog` → `logs.syslog`
- `*.logs.snmp` → `logs.snmp`
- `*.logs.otel` → `logs.otel`
- `*.logs.internal.*` → `logs.internal`

**Implementation:** Updated `docker/compose/zen.docker.json` with corrected subjects and switched zen to file-based config (`CONFIG_SOURCE=file`) instead of KV-based config.

### Decision 4: Use File-Based Config for zen

**What:** Switch zen from KV-based config to file-based config.

**Why:** The KV-based config was loading stale/incorrect configuration from NATS. Using file-based config ensures zen uses the corrected subjects from the mounted config file.

**Implementation:**
```yaml
zen:
  environment:
    - CONFIG_SOURCE=file
    - CONFIG_PATH=/etc/serviceradar/zen.json
```

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Sequential startup is slower | Acceptable for dev environment; parallelism not critical |
| core-elx becomes single point of failure | Only affects dev stack; prod uses different deployment |
| zen auth fix may require new NATS credentials | Can generate with existing nats-creds-init tooling |

## Startup Order (After Fix)

```
cert-generator
    |
cert-permissions-fixer, cloak-keygen
    |
cnpg (wait: healthy)
    |
nats-creds-init, nats-config-init
    |
nats (started)
    |
datasvc (wait: healthy)
    |
core-elx (wait: healthy)  <-- new dependency point
    |
web-ng, agent-gateway, agent, zen, db-event-writer (wait: core-elx healthy)
    |
caddy (wait: web-ng healthy)
```

## Open Questions

1. ~~Does zen need its own NATS user, or can it share platform credentials with extended permissions?~~ **Resolved:** zen works with platform credentials once subjects are corrected.
2. ~~Should we add restart backoff delays to prevent rapid restart loops?~~ **Resolved:** The `depends_on` health conditions prevent restart loops.
3. Is the agent healthcheck failing due to a real issue or just timing? (Pre-existing issue, not addressed in this change)
