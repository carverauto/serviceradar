## 1. Implementation
- [x] 1.1 Add explicit network aliases for the agent gateway service in `docker-compose.yml`.
- [x] 1.2 Update docker agent bootstrap configs to use the compose gateway alias consistently.
- [x] 1.3 Gate agent startup on agent-gateway readiness (health/dependency or wait-for-port).
- [x] 1.4 Update Docker Compose docs to call out the gateway DNS alias and expected enrollment log line.
- [x] 1.5 Verify `docker compose up -d` results in agent enrollment and no gateway connection timeouts.
