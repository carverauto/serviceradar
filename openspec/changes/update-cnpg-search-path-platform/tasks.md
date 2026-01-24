## 1. Implementation
- [x] 1.1 Update Helm CNPG bootstrap SQL to set database/role search_path to `platform, ag_catalog` and ensure the platform schema is owned by `serviceradar`.
- [x] 1.2 Update Docker Compose CNPG init SQL to enforce the same search_path and schema ownership.
- [x] 1.3 Add/adjust bootstrap ownership guards so Oban tables/sequences are owned by `serviceradar` when present.

## 2. Validation
- [ ] 2.1 Verify the rendered Helm CNPG bootstrap SQL includes platform-first search_path and schema ownership.
- [ ] 2.2 (Optional) Smoke test a fresh docker-compose CNPG init to confirm search_path and schema ownership.
