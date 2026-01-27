## 1. Implementation
- [x] 1.1 Move faker service out of docker-compose.yml into a dev-only compose file (docker-compose.dev.yml or a new dev overlay)
- [x] 1.2 Ensure the dev compose path documents how to opt in to faker and starts cleanly with required network/ports
- [x] 1.3 Update docs that reference faker being in the default compose stack (cmd/faker/README.md, Docker quickstart/README as needed)
- [x] 1.4 Validate compose config: default stack excludes faker; dev stack includes faker when enabled
