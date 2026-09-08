## 1. Discovery
- [x] 1.1 Enumerate services using KV config and document current config sources
- [x] 1.2 Audit `pkg/config` and `rust/kvutil` for current consumers
- [x] 1.3 Identify Compose/bootstrap scripts or docs that assume KV for service config

## 2. Implementation
- [x] 2.1 Remove KV config seeding/watching from all services
- [x] 2.2 Update services to load JSON/YAML config files or gRPC-provided configs only
- [x] 2.3 Simplify shared config utilities to remove KV config paths
- [x] 2.4 Remove `rust/kvutil` if unused, or document remaining usage

## 3. Docs & Migration
- [x] 3.1 Update documentation for service configuration sources
- [x] 3.2 Provide migration notes for deployments currently using KV-backed config

## 4. Validation
- [ ] 4.1 Add/update tests or smoke checks for collector config loading (file/gRPC)
- [x] 4.2 Run relevant unit tests for affected services
