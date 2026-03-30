# Change: Harden Docker Compose secret defaults and bootstrap integrity

## Why
The main Docker Compose stack still relies on static default secret material for several trust boundaries, publishes the unauthenticated NATS monitoring endpoint to the host by default, and downloads SPIRE bootstrap binaries at runtime without integrity verification. Those defaults make cross-install secret reuse and supply-chain compromise materially easier than they should be.

## What Changes
- remove shipped static default secret material for Docker Compose cluster/distribution, Phoenix signing, and plugin download signing
- generate per-install compose secrets during bootstrap and wire services to file-backed or generated values
- stop publishing NATS monitoring externally by default, or restrict it to loopback/internal-only exposure
- remove unsigned runtime SPIRE binary downloads from the compose bootstrap path by using pinned local binaries or verified artifacts

## Impact
- Affected specs: `docker-compose-stack`
- Affected code: `docker-compose.yml`, `docker/compose/update-config.sh`, `docker/compose/bootstrap-admin.sh`, `docker/compose/nats.docker.conf`, `docker/compose/spire/bootstrap-compose-spire.sh`, `docker/compose/spire/run-agent.sh`
