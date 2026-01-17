# Tasks: Fix Docker Compose Stack

## 1. Investigate and Document
- [x] 1.1 Document current service status and errors
- [x] 1.2 Identify root causes of failures
- [x] 1.3 Create proposal with fix plan

## 2. Fix Distributed Erlang Clustering
- [x] 2.1 Add `depends_on: core-elx: condition: service_healthy` to web-ng
- [x] 2.2 Add `depends_on: core-elx: condition: service_healthy` to agent-gateway
- [x] 2.3 Consider staggered startup delays or sequential cluster joining
- [x] 2.4 Verify Horde processes don't conflict after dependency changes

## 3. Fix JetStream/NATS Configuration
- [x] 3.1 Review zen's required NATS subjects and stream configuration
- [x] 3.2 Update zen config to use `*.logs.internal.*` instead of `*.logs.internal.>`
- [x] 3.3 Switch zen to file-based config (`CONFIG_SOURCE=file`)
- [ ] 3.4 Verify zen can connect and install initial rules (BLOCKED: NATS account permissions)

> **Note:** zen still fails due to JetStream subject pattern issues. The `*.*.processed` pattern
> triggers NATS error 10052. This requires investigation into NATS account JWT permissions or
> changes to zen's stream subject handling. Tracked separately.

## 4. Fix Health Checks
- [x] 4.1 Add healthcheck to db-event-writer service
- [ ] 4.2 Review and fix agent healthcheck (pre-existing issue)
- [x] 4.3 Caddy healthcheck now works (fixed by web-ng stabilization)
- [x] 4.4 Add healthcheck to zen service

## 5. Fix Dependency Chain
- [x] 5.1 Review all `depends_on` relationships in docker-compose.yml
- [x] 5.2 Ensure proper startup order with health conditions
- [x] 5.3 Add missing dependencies (web-ng and agent-gateway depend on core-elx healthy)

## 6. Test and Validate
- [x] 6.1 Restart services with `docker compose up -d --force-recreate`
- [x] 6.2 Verify main services reach healthy state (web-ng, agent-gateway, caddy, db-event-writer)
- [x] 6.3 Check logs - main services stable
- [x] 6.4 Confirm caddy healthy (proxies to web-ng successfully)

## Results Summary

| Service | Before | After |
|---------|--------|-------|
| web-ng | Crashing | ✅ Healthy |
| agent-gateway | Restarting | ✅ Healthy |
| caddy | Unhealthy | ✅ Healthy |
| db-event-writer | No healthcheck | ✅ Healthy |
| core-elx | Healthy | ✅ Healthy |
| zen | Exited (1) | ⚠️ Still failing (NATS auth) |
| agent | Unhealthy | ⚠️ Pre-existing issue |

## Remaining Work
1. zen NATS authorization - requires NATS account JWT investigation
2. agent unhealthy - pre-existing issue, unrelated to this change
