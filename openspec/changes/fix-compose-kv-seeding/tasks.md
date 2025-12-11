## 1. Implementation
- [x] 1.1 Update docker-compose.yml (mtls/podman variants) to run KV-managed services with `CONFIG_SOURCE=kv` and the required `KV_*` credentials so they seed defaults into datasvc.
- [x] 1.2 Apply the same KV-backed config sourcing to poller-stack compose variants and any tooling containers that seed templates.
- [x] 1.3 Add Compose documentation/checklist covering KV seeding expectations and watcher telemetry verification after first boot.
- [x] 1.4 Validate from a clean Compose bring-up that KV holds core/agent/poller (and other managed) configs and watcher telemetry shows all compose services.
