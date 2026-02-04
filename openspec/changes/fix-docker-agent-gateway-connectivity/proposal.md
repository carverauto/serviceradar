# Change: Ensure Docker Compose agent can reach agent-gateway

## Why
A fresh Docker Compose install on v1.0.90 shows agents timing out when connecting to `agent-gateway:50052`, leaving the stack without agent enrollment. The default compose stack should guarantee that agents can resolve and reach the gateway without manual edits.

## What Changes
- Ensure the Docker Compose network exposes stable aliases for the agent gateway that match the agent bootstrap config.
- Align the agent bootstrap config with the gateway alias used in compose.
- Add startup sequencing/health checks so the agent does not start pushing before the gateway gRPC listener is ready.

## Impact
- Affected specs: `docker-compose-stack`
- Affected code: `docker-compose.yml`, `docker/compose/agent.mtls.json`, `docker/compose/agent.docker.json`, `docker/compose/agent-minimal.docker.json`, docs for Docker Compose if needed
