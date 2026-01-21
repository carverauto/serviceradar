# Change: Fix Docker Compose Stack Health Issues

## Why

The local Docker Compose development stack is unhealthy with multiple services failing to start properly or crashing repeatedly. This blocks local development and testing. The root causes are distributed Erlang clustering race conditions, JetStream configuration issues, and missing health checks.

## Issue Summary

| Service | Status | Issue |
|---------|--------|-------|
| web-ng | Crashing/Restarting | Horde clustering conflicts with core-elx |
| agent-gateway | Restarting | Same Horde clustering conflict |
| zen | Exited (1) | JetStream no-ack config + NATS auth violations |
| caddy | Unhealthy | Can't proxy to unstable web-ng |
| db-event-writer | Running (no healthcheck) | NATS heartbeat timeouts, no healthcheck |
| agent | Unhealthy | Health check failing despite functional service |
| core-elx | Healthy | Primary node but causes cluster conflicts |
| cnpg | Healthy | OK |
| datasvc | Healthy | OK |
| nats | Running | OK but JetStream config needs adjustment |

## Root Causes

### 1. Distributed Erlang Clustering Race Condition
Multiple Elixir apps (core-elx, web-ng, agent-gateway) use Horde for distributed supervision and are configured to form a cluster via EPMD. When they all start simultaneously:
- First service to start (typically core-elx) registers Horde supervisors
- Other services fail with "already started" errors when trying to join
- This causes crash loops in web-ng and agent-gateway

### 2. JetStream Stream Configuration
zen service fails because:
- Subjects overlap with JetStream API and require `no-ack: true`
- Stream "events" not configured with the correct subject patterns
- zen can't install initial rules due to NATS authorization

### 3. Missing/Incorrect Health Checks
- db-event-writer has no healthcheck defined
- agent shows unhealthy but is functioning
- caddy depends on web-ng healthcheck which fails during crash loops

## What Changes

### Clustering Fixes
- **BREAKING**: Change clustering strategy from simultaneous join to sequential startup
- Add `depends_on` with health conditions so web-ng and agent-gateway wait for core-elx
- Consider making core-elx the "leader" node that others connect to

### JetStream/NATS Fixes
- Update NATS config to handle zen's subject requirements
- Add proper NATS credentials for zen service to install rules
- Fix events stream configuration for no-ack subjects

### Health Check Fixes
- Add healthcheck to db-event-writer service
- Adjust agent healthcheck or increase tolerance
- Make caddy health check more resilient to temporary upstream failures

### Dependency Chain Fixes
- Add proper `depends_on` conditions with `service_healthy` where needed
- Ensure startup order: cert-gen -> cnpg -> nats -> datasvc -> core-elx -> web-ng -> agent-gateway -> caddy

## Impact

- Affected specs: None (infrastructure change)
- Affected code:
  - `docker-compose.yml` - service definitions, dependencies, health checks
  - `docker/compose/nats.docker.conf` - JetStream configuration
  - `docker/compose/zen.docker.json` - zen configuration
