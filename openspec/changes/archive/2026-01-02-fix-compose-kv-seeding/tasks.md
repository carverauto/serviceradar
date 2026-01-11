## 1. Implementation
- [x] 1.1 Update docker-compose.yml (mtls variants) to run KV-managed services with `CONFIG_SOURCE=kv` and the required `KV_*` credentials so they seed defaults into datasvc.
- [x] 1.2 Apply the same KV-backed config sourcing to poller-stack compose variants and any tooling containers that seed templates.
- [x] 1.3 Add Compose documentation/checklist covering KV seeding expectations and watcher telemetry verification after first boot.
- [x] 1.4 Validate from a clean Compose bring-up that KV holds core/agent/poller (and other managed) configs and watcher telemetry shows all compose services.
- [x] 1.5 Build and publish a stable zen image that ignores the initial KV watch event and update Compose to use it.
- [x] 1.6 Ship the serviceradar-tools image with a Compose-friendly NATS context (auto-selected for tls://nats:4222) so JetStream/KV can be inspected without nats-box.
