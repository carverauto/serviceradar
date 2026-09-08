# Tasks: Fix Docker Compose upgrade config clobbering

- [x] 1. Capture current Compose boot/upgrade behavior and identify which volumes/keys are required to preserve sysmon/system metrics.
- [x] 2. Update `docker-compose.yml` to explicitly name stateful volumes (at minimum `generated-config`, `nats-data`, and `cert-data`).
- [x] 3. Update `docker/compose/update-config.sh` to:
  - [x] 3.1. Avoid clobbering existing configs during upgrades.
  - [x] 3.2. Preserve existing generated configs by default; require an explicit opt-in env (e.g., `FORCE_REGENERATE_CONFIG=true`) to rewrite templates.
  - [x] 3.3. Fix KV placeholder-repair so partial overlays do not get rewritten during restarts/upgrades.
  - [x] 3.4. Remove checker-specific bootstrap logic (rely on KV/UI + templates instead).
- [x] 4. Add/extend local verification steps:
  - [x] 4.1. Fresh `docker compose up` produces a poller config with a non-empty sysmon endpoint.
  - [x] 4.2. Upgrade-style `docker compose up -d --force-recreate` preserves sysmon endpoint and does not reset KV-managed config.
- [x] 5. Document the safe upgrade procedure in `docs/docs/docker-setup.md`.
- [x] 6. Run `openspec validate fix-compose-upgrade-config-clobbering --strict`.
