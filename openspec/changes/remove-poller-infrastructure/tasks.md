## 1. Implementation
- [ ] 1.1 Inventory poller references across code, configs, docs, and tests.
- [ ] 1.2 Remove poller resources, registrations, and runtime lookups in Elixir core; replace with gateway/agent equivalents where required.
- [ ] 1.3 Remove poller UI pages, SRQL mappings, and test fixtures in web-ng.
- [ ] 1.4 Remove poller Docker compose services, configs, and image targets.
- [ ] 1.5 Remove Go/Rust poller artifacts and build/test targets if no longer used.
- [ ] 1.6 Update docs and runbooks to remove poller references.
- [ ] 1.7 Update OpenSpec deltas and ensure specs reflect gateway/agent architecture.
- [ ] 1.8 Run `make lint`, `make test`, and `mix precommit` (web-ng) after updates.
