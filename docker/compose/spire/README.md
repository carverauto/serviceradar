# Docker Compose SPIRE Runtime

This directory now contains the configuration and helper scripts that power the
zero-touch SPIRE deployment used by `docker compose up`. The compose stack
launches a dedicated `spire-server`, seeds registration entries for every
ServiceRadar workload, and starts a shared `spire-agent` that exposes the
Workload API over `/run/spire/sockets/agent.sock`.

Files:

- `server.conf` – standalone SPIRE server configuration backed by SQLite.
- `agent.conf` – SPIRE agent configuration that talks to the local server.
- `bootstrap-compose-spire.sh` – idempotent helper invoked by the
  `serviceradar-spire-bootstrap` service to generate the join token for the
  compose agent and to register all workload identities (core, datasvc, poller,
  agent, sync, collectors, etc.).
- `run-agent.sh` – wrapper that reads the generated join token, waits for the
  shared socket directory, and then launches `spire-agent`.
- `upstream-join-token`, `upstream-bundle.pem` – optional artifacts still used by
  the edge poller tooling (`docker/compose/edge-*`). These files are ignored by
  git so operators can fetch upstream credentials without committing them.

The entire SPIRE lifecycle is now self-managed: running `docker compose up`
starts the server/agent pair automatically, and every container mounts the
shared socket volume so they can obtain SPIFFE SVIDs without any manual
preparation.
