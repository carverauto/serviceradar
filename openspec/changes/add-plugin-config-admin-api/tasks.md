# Tasks

- [x] 1. Admin API for credential secrets and rules
  - [x] 1.1 Add `/api/admin/network-credential-secrets` list/get/create/update/rotate on `:api_key_auth`
  - [x] 1.2 Create uses `CredentialSecretBuilder` and never returns `secret_payload`
  - [x] 1.3 Add `/api/admin/network-credential-rules` list/get/create/update/enable/disable
  - [x] 1.4 Rule create/update accepts TLS policy, CA bundle, fingerprint, and metadata
  - [x] 1.5 Document the paths in the admin OpenAPI spec
  - [x] 1.6 Controller tests for auth, RBAC, and secret redaction

- [x] 2. Admin API for Ansible controllers
  - [x] 2.1 Add `/api/admin/ansible-controllers` list/get/create/update/enable/disable
  - [x] 2.2 Bind credentials by secret id only; never echo tokens
  - [x] 2.3 Document in OpenAPI and add controller tests

- [x] 3. Close plugin-assignment API gaps
  - [x] 3.1 Add `GET /api/admin/plugin-assignments/{id}`
  - [x] 3.2 Include `plugin_id` (and existing fields) on assignment JSON

- [x] 4. CLI device-code scope
  - [x] 4.1 Add `plugins.manage` to `Auth.NarrowScopes` for the new routes plus assignment CRUD
  - [x] 4.2 Migration: add `plugins.manage` to the default for new policy rows; preserve existing rows
  - [x] 4.3 Update CLI auth fallback lists and NarrowScopes tests

- [x] 5. Extend `serviceradar-cli`
  - [x] 5.1 `plugin assignments|secrets|rules|controllers` list/get/create/update
  - [x] 5.2 `plugin apply --file` idempotent playbook apply (env-sourced secrets)
  - [x] 5.3 Help text, README, version bump (0.1.6)
  - [x] 5.4 CLI tests against a canned HTTP server

- [ ] 6. Demo playbook
  - [x] 6.1 Check in `playbooks/demo-plugins.yaml` with non-secret params and env var names
  - [x] 6.2 Document apply against demo.serviceradar.cloud
  - [ ] 6.3 Prove apply against demo (or local-web-ng) and show assignments/rules via the API

- [x] 7. Docs
  - [x] 7.1 Update `docs/docs/credentials.md` so it no longer claims there is no REST surface

## Verification recorded before subsequent review fixes

- `openspec validate add-plugin-config-admin-api --strict`: valid.
- `js/cli`: `npm run ci` green (typecheck, build, 53 node tests incl. new
  `plugin-apply` canned-server tests, pack check).
- `elixir/web-ng`: `mix compile --warnings-as-errors` green (test env).
- Focused ExUnit run against a scratch `codex_*` database on the
  `srql-fixtures` CNPG cluster (baselined + migrated, including
  `20260905120000`): 21 tests, 0 failures across the four new controller
  test files plus the OpenAPI spec test.
- Real `playbooks/demo-plugins.yaml` dry-run through the built CLI against a
  stub admin API: the playbook at that revision
  planned correctly; this is not verification of the current playbook.

## Why 6.3 stays open

A live apply needs this branch deployed (demo runs staging, which lacks the
new routes) plus real demo secret values and a product API token. That is a
post-merge rollout step: merge, release, roll demo, then run
`serviceradar-cli plugin apply --file playbooks/demo-plugins.yaml` with the
demo env vars set and confirm via
`plugin assignments/rules/controllers list`. No secrets belong in git at any
point.
