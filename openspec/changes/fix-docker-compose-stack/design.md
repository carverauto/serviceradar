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

**What:** The zen service fails because its stream subjects overlap with JetStream API requirements.

**Why:** NATS JetStream has specific requirements for certain subject patterns. The error "subjects that overlap with jetstream api require no-ack to be true" indicates the events stream needs configuration changes.

**Options considered:**
1. ~~Modify zen to use different subject patterns~~ - Requires zen code changes
2. **Configure NATS stream with allow_direct** - Stream-level config change
3. Use different stream for zen - More complex

**Implementation:** Review and update the NATS JetStream stream configuration in datasvc initialization or zen startup to handle the subject pattern requirements.

### Decision 4: Handle zen NATS Authorization

**What:** zen fails with "authorization violation" when trying to install initial rules.

**Why:** The zen service may need additional NATS permissions or the correct credentials file.

**Implementation:**
- Verify zen has correct creds file mounted
- Check platform.creds includes permissions for zen's KV operations
- May need zen-specific NATS user with appropriate permissions

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

1. Does zen need its own NATS user, or can it share platform credentials with extended permissions?
2. Should we add restart backoff delays to prevent rapid restart loops?
3. Is the agent healthcheck failing due to a real issue or just timing?
