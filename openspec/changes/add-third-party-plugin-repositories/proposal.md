# Change: Multiple plugin repositories, including private third-party sources

## Why

**The catalog repository field on Settings → Agents → Plugins is a view-local text box, not a
setting.** `select_first_party_repository`
(`elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/plugin_package_live/index.ex:355-368`) assigns
the submitted URL to `socket.assigns.first_party_repo_url` and nothing else. It is never persisted,
so it resets to `first_party_repo_url/0` (`:3055-3058`, reading `:first_party_plugin_import`
`:repo_url` from config) on the next mount, and `FirstPartySyncWorker` — the thing that actually
performs recurring imports — resolves its repo from the same config
(`lib/serviceradar_web_ng/plugins/first_party_sync_worker.ex:74-77`). A user can point the *browsing
view* at another repository; the *background import* keeps pulling from `carverauto/serviceradar`.

**Even pointed at a third-party repository, every import fails, for two independent reasons.**

1. **One global signing key.** `plugin_verification_policy/0` (`plugins/packages.ex:893-909`) reads a
   single `trusted_upload_signing_keys` map from `:plugin_verification` config, which ships exactly
   two entries, both first-party (`config/config.exs:299-302`). `enforce_upload_policy/2` (`:875-890`)
   checks every package against that one map, so a bundle signed with a vendor's own ed25519 key is
   rejected. The same map is read again during import at `first_party_importer.ex:513-521`.
2. **One OCI registry.** `validate_oci_registry/1`
   (`plugins/first_party_release_client.ex:181-182`) returns `{:error, :untrusted_oci_registry}` for
   anything but `registry.carverauto.dev`.

**Private repositories do not work at all.** `fetch_release_asset/2`
(`first_party_release_client.ex:117-131`) downloads from the asset's `browser_download_url`, which
returns 404 for a PAT against a private repo — private release assets require
`GET /repos/{owner}/{repo}/releases/assets/{id}` with `Accept: application/octet-stream`. And
`auth_headers/0` (`:508-515`) reads one process-global `GITHUB_TOKEN`/`GH_TOKEN`; there is no
per-repository credential, so two teams' private repos cannot both be reachable.

**Nothing about source trust is audited.** Choosing which repository is trustworthy is a higher-
privilege act than staging a package from an already-trusted one — it decides what "verified" means
— yet today it is a text box gated on `plugins.stage` (`:351-353`) with no persistence, no audit
record, and no event.

**The cosign requirement that would make this a heavy lift does not apply.** `fetch_artifact/2`
(`first_party_importer.ex:240-251`) already has two paths, and only `fetch_oci_artifact/2` (`:269`)
calls cosign. `fetch_direct_artifact/2` (`:253-267`) pulls a bundle and an ed25519 upload signature
as ordinary release assets — no cosign, no OCI registry, no Rekor. The signature required on both
paths is the plain ed25519 `UploadSignature` (`plugins/upload_signature.ex:7-25`), and the signer
already exists as a dependency-free Go binary, `build/wasm_plugins/upload_signature_tool.go`, which
cross-compiles to macOS and Windows. A third-party developer runs one binary; the platform stores
one base64 public key. This also avoids `CosignVerifier`'s mandatory public Rekor transparency-log
entry (`plugins/cosign_verifier.ex:69-82`), which for a private repository would publish repository
and workflow identity to a public log.

## What Changes

- **New `platform.plugin_repositories` table and `ServiceRadar.Plugins.PluginRepository` Ash
  resource.** Carries the repo URL, display name, per-repository ed25519 trusted signing key
  (`signing_key_id` + `signing_public_key`), `index_asset_name`, `enabled`, `builtin`, `is_default`,
  an `artifact_kind` column fixed at `:wasm_plugin` for now, and an optional
  `credential_secret_id` FK for private repositories.
- **Private-repository support via the existing credential store.** A repository may reference a
  `ServiceRadar.Credentials.NetworkCredentialSecret` with `credential_kind: :api_token` holding a
  GitHub PAT — AshCloak-encrypted at rest, with the paper trail, rotation and resolution audit that
  resource already provides. `fetch_release_asset/2` moves to the asset API endpoint and
  `auth_headers/0` becomes per-repository, with the Authorization header deliberately *not*
  following the redirect to the pre-signed asset host.
- **Per-repository verification.** `plugin_verification_policy/0` and `verify_upload_signature/3`
  resolve trusted signing keys from the importing repository record instead of global config.
  A repository without a signing key cannot be saved, and an import whose signature does not verify
  against *that repository's* key is rejected.
- **Seeded built-in repository.** A migration seeds `carverauto/serviceradar` as `builtin: true`,
  `is_default: true`, with the two existing first-party keys. It cannot be edited or deleted, only
  disabled, so every import — foreground and background — reads one repository row through one code
  path.
- **Dropdown plus modal on Settings → Agents → Plugins.** The free-form input becomes a `<select>`
  of enabled repositories with the built-in default preselected, ending in an `… Add New` option
  that opens a modal for name, URL, signing key, index asset name and optional PAT. Saved
  repositories can be edited, disabled and removed from the same surface.
- **New RBAC permission `plugins.repositories.manage`**, admin-only, deliberately *not* implied by
  `plugins.stage`. Enforced in the LiveView and independently by an Ash policy on the resource.
- **Audit trail and events.** A `PluginRepositoryNotifier` writes OCSF audit records through
  `ServiceRadar.Events.AuditWriter` on create/update/enable/disable/destroy, recording actor, repo
  URL, and signing-key id — never the PAT.
- **`FirstPartySyncWorker` iterates enabled repositories** instead of importing from a single
  configured URL, so a third-party repo participates in recurring sync.

**BREAKING**: none at the API or agent boundary. The `:first_party_plugin_import` `:repo_url` and
`:plugin_verification` `:trusted_upload_signing_keys` config keys become seed values for the
built-in row rather than the live source of truth for every import.

## Impact

- **Affected specs**: `wasm-plugin-system`, `build-web-ui`
- **Affected code**:
  - New: `elixir/serviceradar_core/lib/serviceradar/plugins/plugin_repository.ex`,
    `plugin_repository_notifier.ex`, `elixir/web-ng/lib/serviceradar_web_ng/plugins/repositories.ex`,
    one migration under `elixir/serviceradar_core/priv/repo/migrations/`
  - Verification/transport: `plugins/packages.ex`, `plugins/first_party_importer.ex`,
    `plugins/first_party_release_client.ex`, `plugins/first_party_sync_worker.ex`
  - UI: `live/admin/plugin_package_live/index.ex`
  - RBAC: `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex`,
    `lib/serviceradar/plugins/policies.ex`
  - Config: `elixir/web-ng/config/config.exs`, `config/runtime.exs`
- **Not in scope**: `/settings/agents/addons` keeps reading `:native_addon_import` config. The
  `artifact_kind` column and per-repository `index_asset_name` exist so it can adopt this later
  without a migration.
