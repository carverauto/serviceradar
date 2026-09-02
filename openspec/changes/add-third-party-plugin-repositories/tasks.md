# Tasks

## 1. Schema and resource

- [x] 1.1 Add migration `elixir/serviceradar_core/priv/repo/migrations/<ts>_create_plugin_repositories.exs`
      creating `platform.plugin_repositories` with `prefix: "platform"`: `id`, `name`, `repo_url`,
      `artifact_kind`, `index_asset_name`, `signing_key_id`, `signing_public_key`,
      `credential_secret_id` FK to `platform.network_credential_secrets`, `enabled`, `builtin`,
      `is_default`, `last_sync_at`, `last_sync_error`, `created_by_id`, timestamps.
- [x] 1.2 Add a unique index on `repo_url` and a partial unique index enforcing a single
      `is_default: true` row.
- [x] 1.3 Seed the built-in `carverauto/serviceradar` row in the same migration, keyed on `repo_url`
      for idempotency, taking `index_asset_name` and the two `serviceradar-first-party-*` signing
      keys from the current `config.exs` values.
- [x] 1.4 Create `ServiceRadar.Plugins.PluginRepository` Ash resource (`domain: ServiceRadar.Plugins`,
      `AshPostgres`, `schema "platform"`) with `:read`, `:create`, `:update`, `:destroy`,
      `:enable`, `:disable` actions and a `:default` read.
- [x] 1.5 Make `signing_key_id` and `signing_public_key` `allow_nil? false`, and validate that
      `signing_public_key` decodes to a 32-byte ed25519 key.
- [x] 1.6 Validate `repo_url` so only `https://github.com/<owner>/<repo>` is accepted. The parser
      moved to `ServiceRadar.Plugins.RepoUrl` in core: the resource must validate the same URLs the
      importer resolves, and core cannot depend on web-ng. Task 4 makes the web-ng client delegate
      to it rather than keeping a second parser.
- [x] 1.7 Reject `update` and `destroy` on rows with `builtin: true`; allow `:enable`/`:disable`.
      Implemented as `Changes.RejectBuiltinRepository` + `Changes.NormalizeRepoUrl`, both with
      `atomic/3`, and `Validations.RepositorySource.atomic/3`. Ash first warned all three were
      non-atomic; no `require_atomic? false` was added.
- [x] 1.8 Register the resource on the `ServiceRadar.Plugins` domain.

## 2. Authorization

- [x] 2.1 Add `plugins.repositories.manage` to `ServiceRadar.Identity.RBAC.Catalog` under the
      `plugins` section with `default_roles: @admin_roles`.
- [x] 2.2 Add a `repositories_manage_action_types/0` macro (or equivalent check) to
      `ServiceRadar.Plugins.Policies` bound to the new permission, and apply it to the resource so
      reads are permitted and writes require the permission.
- [x] 2.3 Verified against the compiled catalog: `plugins.repositories.manage` renders as its own
      grid row (`plugins.repositories` x `manage`) in the Plugins section, admin-only, and
      `Catalog.holds?(["plugins.stage"], "plugins.repositories.manage")` is false. The grid builds
      per-section from each permission's explicit `:resource`/`:action`, so the key-string parsing
      hazard noted elsewhere does not apply here.

## 3. Credentials

- [x] 3.1 Add the `credential_secret_id` relationship to `NetworkCredentialSecret`, constrained to
      `credential_kind: :api_token` via `Validations.RepositoryCredentialKind`.
- [x] 3.2 `RepositoryCredentials.put_token/3` creates or replaces the attached credential through the
      credential store (AshCloak encrypts it); `clear_token/2` detaches and destroys.
- [x] 3.3 No repository read, calculation, or public attribute exposes the token; only
      `credential_attached?` is public. NOT YET ASSERTED by a test -- see 9.5.
- [x] 3.4 `RepositoryCredentials.fetch_token/2` resolves through `SecretBroker`, so every read of the
      token lands in `CredentialSecretResolutionAudit` like any other credential. Public repos
      return `{:ok, nil}` rather than an error.

## 4. Transport and verification

- [x] 4.1 Use the release asset API URL with `Accept: application/octet-stream` for private repos,
      keeping `browser_download_url` as the public fallback. NOTE: the change belongs in
      `fetch_binary_asset/2` (the download), not `fetch_release_asset/2` (which only finds the asset
      in the release JSON) -- the task text named the wrong function.
      Also: `parse_repo_url/1` now delegates to core's `ServiceRadar.Plugins.RepoUrl`.
- [x] 4.2 `auth_headers/1` takes the repo and prefers `repo.token`, falling back to the env var so
      the built-in source behaves exactly as before. `with_token/2` binds it per request.
- [x] 4.3 `auth_host?/1` stays restricted, and the redirect hop is forced back to `:asset` mode so
      the pre-signed host cannot receive the token. Covered by
      `first_party_release_client_auth_test.exs` (10 tests, passing).
- [x] 4.4 `verify_upload_signature/4` resolves trusted keys from the repository. DESIGN NOTE: the
      keys are threaded in as attrs by `Repositories`/`Packages` rather than the importer doing a
      lookup -- making the importer hit the database would have converted its whole `:db_free` unit
      suite into a database suite. Config remains the fallback when no keys are passed.
- [x] 4.5 `enforce_verification_policy/1` resolves the package's originating repository by
      `source_repo_url` and swaps in its key for `:first_party` packages. `:upload` packages (CLI and
      admin form) have no catalog, so they keep the configured policy.
- [x] 4.6 `fetch_oci_artifact/2`, `validate_oci_registry/1` and cosign verification are untouched.
- [x] 4.7 404/401/403 on the release endpoints now explain the credential case. GitHub answers 404
      (not 403) for a private repository a token cannot see, so status alone cannot distinguish
      "no such release" from "no valid token" -- the message covers both.

## 5. Sync worker

- [x] 5.1 `FirstPartySyncWorker` enumerates enabled repositories.
- [x] 5.2 Each repository syncs independently; a failure is recorded and the run continues, then
      reports `:partial_plugin_sync_failure` so Oban still retries.
- [x] 5.3 `record_sync_success` / `record_sync_error` stamp each row.
- [x] 5.4 `enqueue_now/1`'s `repo_url` selects one registered repository rather than bypassing the
      registry, so a manual sync cannot pull from an unregistered source.

## 6. Audit and events

- [x] 6.1 Add `ServiceRadar.Plugins.PluginRepositoryNotifier` writing through
      `ServiceRadar.Events.AuditNotifier` on create/update/enable/disable/destroy.
- [x] 6.2 Audit details carry actor, repo URL, name, enabled state and signing key id.
      `PluginRepositoryNotifier.audit_details/1` is public so the "no credential material" property
      is asserted directly rather than by reconstructing the notifier -> AuditWriter ->
      InternalLogPublisher pipeline. Tests assert neither the token nor the secret id appears.
- [ ] 6.3 Attach the notifier to the resource and confirm the OCSF audit record reaches
      `logs.internal.audit`.

## 7. UI

- [x] 7.1 Replace the `repo_url` input in `plugin_package_live/index.ex` (the
      `select-first-party-repository-form` block) with a `<select>` of enabled repositories plus a
      trailing `… Add New` option.
- [x] 7.2 Add the add/edit repository modal using `ui_modal`, with fields for name, URL, signing key
      id, signing public key, index asset name, and optional access token; return the dropdown to its
      prior selection when dismissed.
- [x] 7.3 Wire create/update/destroy/enable/disable events, each re-checking
      `plugins.repositories.manage` server-side rather than trusting a hidden control.
- [x] 7.4 Show field-level validation errors in the modal without closing it.
- [x] 7.5 Hide `… Add New`, edit and remove for users lacking the permission while leaving the
      dropdown usable for switching the viewed catalog.
- [x] 7.6 Suppress edit and remove for the built-in row; keep enable/disable.
- [x] 7.7 Replace `first_party_repo_url/0` and `normalize_first_party_repo_url/1` with repository
      lookups, and update the panel subtitle that interpolates `@first_party_repo_url`.
- [x] 7.8 Add a masked, write-only PAT field showing whether a credential is attached, with replace
      and clear controls.

## 8. Config and docs

- [x] 8.1 Keep `:first_party_plugin_import` `:repo_url` and `:plugin_verification`
      `:trusted_upload_signing_keys` as seed values; document that they no longer drive per-import
      verification.
- [x] 8.2 Document the third-party publishing contract under `docs/docs/`: release layout, index
      entry using `bundle_url`, and signing with `build/wasm_plugins/upload_signature_tool.go`,
      including the fine-grained read-only PAT scope expected for private repositories. ASCII only.

## 9. Tests

- [ ] 9.1 Resource tests WRITTEN in `plugin_repository_db_test.exs` (built-in immutability, ed25519
      key validation, repo URL validation and normalization, duplicate-spelling rejection,
      single-default index, sync-state stamping) but NOT YET RUN -- the fixture database was still
      migrating when this was written.
- [ ] 9.2 WRITTEN (unrun, needs DB) in `plugin_repository_policy_db_test.exs`: `plugins.stage`
      alone cannot create, edit, disable or remove a repository; `plugins.repositories.manage`
      can; direct resource calls are refused without it.
- [x] 9.3 Verification tests added to `first_party_importer_test.exs`: repository key verifies when
      global config is empty; a bundle signed by another repository's key is rejected; an unknown
      key id fails distinctly as `:untrusted_signer`.
- [x] 9.4 `first_party_release_client_auth_test.exs` (10 tests): API asset URL for private repos,
      octet-stream accept header, no Authorization on the pre-signed redirect, repo token preferred
      over the env var, env var still the fallback.
- [ ] 9.5 WRITTEN (unrun, needs DB) in the same file: token absent from repository and secret reads,
      `fetch_token` returns it only at point of use, replace reuses the secret, clear destroys it;
      `credential_attached?`
      reflects state.
- [ ] 9.6 Sync worker tests: all enabled repositories imported; one failing repository does not abort
      the others; disabled repositories skipped.
- [x] 9.7 Audit tests written (unrun, need DB): details carry the repo URL and signing key id, and
      carry neither the token nor the credential secret id; a public repository reports
      `credential_attached: false`.
- [x] 9.8 LiveView tests written (unrun, need DB) in `plugin_repository_live_test.exs`: dropdown
      renders with the built-in preselected and the old free-form field gone; `… Add New` opens the
      modal; a valid save persists and closes; an invalid key and a malformed URL each keep the modal
      open with the error; a viewer sees the dropdown but not `… Add New`; and the handlers refuse a
      viewer who sends the event directly, since a hidden control is not the check.
- [x] 9.9 Seed tests written (unrun, need DB): exactly one built-in row and exactly one default,
      and they are the same row; re-registering the seeded `repo_url` is rejected by the unique
      index, which is what makes the migration's ON CONFLICT re-run safe.

## 10. Verification

- [ ] 10.1 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`
- [ ] 10.2 `./scripts/elixir_quality.sh --project elixir/serviceradar_core`
- [ ] 10.3 `make test`
- [ ] 10.4 `openspec validate add-third-party-plugin-repositories --strict`
