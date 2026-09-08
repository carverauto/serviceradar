## Context

ServiceRadar imports signed Wasm plugin bundles from GitHub Releases. Every trust decision in that
path is currently a compile-time constant or a single global config value: one repository URL, one
map of trusted ed25519 signing keys, one OCI registry host, one `GITHUB_TOKEN`. That is correct for
a single first-party source and wrong for the driving use case — a customer whose developers
publish Wasm plugins to their own **private** GitHub repository, alongside the first-party catalog.

The constraint that shapes this design is friction on the publisher side. A third-party developer on
a macOS or Windows workstation must be able to publish a plugin without operating a signing
infrastructure.

## Goals / Non-Goals

**Goals**

- Multiple plugin repositories, added and removed from the UI, each with its own trust anchor.
- Private GitHub repositories via a per-repository PAT, encrypted at rest.
- Publishing friction for a third-party developer no higher than "run one binary".
- Adding a repository is RBAC-gated, audited, and emits events.
- One code path for "which repository is this import from", covering the built-in source.

**Non-Goals**

- Native add-on repositories. The schema is shaped for them; the UI and importer are not.
- A public plugin marketplace, ratings, or discovery beyond an explicit URL.
- Replacing cosign/OCI for first-party artifacts. That path stays exactly as it is.
- Multitenancy. Repositories are deployment-scoped like every other setting.

## Decisions

### Decision: ed25519 upload signatures are the third-party trust anchor; cosign stays first-party-only

`fetch_artifact/2` (`first_party_importer.ex:240`) already branches on the index entry: an entry with
`bundle_url` takes `fetch_direct_artifact/2`, which fetches the bundle and an upload-signature
document as plain release assets and never invokes cosign. Only `fetch_oci_artifact/2` calls
`verify_cosign_signature/2`. The signature enforced on **both** paths is `UploadSignature.verify/4`
— ed25519 over canonical JSON of `%{"content_hash" => ..., "manifest" => ...}`.

So the third-party contract is: publish a release containing the index JSON, the bundle zip, and a
`.sig` JSON per bundle, with index entries using `bundle_url` rather than `oci_ref`. The publisher
signs with `build/wasm_plugins/upload_signature_tool.go`, an existing dependency-free Go binary that
reads an ed25519 key from env or file. The platform stores that repository's `key_id` and base64
public key.

**Alternatives considered.** *Per-repository cosign key*: cosign is a single binary and installs
cleanly on both platforms, but `CosignVerifier` requires a Rekor transparency-log entry
(`cosign_verifier.ex:69-82`), which for a private repository publishes repo and workflow identity to
a public log; it also drags in an OCI registry the customer does not otherwise need. *Cosign
keyless*: genuinely zero-key inside GitHub Actions, but CI-only — a local publish opens an
interactive browser OIDC flow per signature. *Allowing unsigned repositories*: rejected; an unsigned
repository is arbitrary Wasm fetched from a URL, and the approval queue is not a substitute for
provenance.

**Consequence to hold onto:** a repository row with no signing key is not a weaker repository, it is
an unusable one. `signing_key_id` and `signing_public_key` are `allow_nil? false`, so the failure is
at repository-create time, in the modal, where a human can fix it — not at import time in a
background job.

### Decision: the PAT lives in the existing credential store, referenced by FK

`plugin_repositories.credential_secret_id` references
`ServiceRadar.Credentials.NetworkCredentialSecret` with `credential_kind: :api_token`. That resource
already carries AshCloak encryption into `encrypted_secret_payload`, `AshPaperTrail`, rotation
state, `CredentialSecretResolutionAudit`, and its own policies — all of which a bespoke encrypted
column on the repository row would reimplement. It matches how `IntegrationSource` handles the same
problem (`integration_source.ex`, `credential_secret_id`).

**Alternative considered**: an AshCloak attribute directly on `plugin_repositories`. Fewer moving
parts and no cross-domain FK, but it duplicates rotation, redaction and resolution audit, and a PAT
is precisely the `:api_token` primitive the credential store exists to hold.

**Consequence:** repository reads must never load the decrypted payload. The secret is resolved at
fetch time inside the release client, and the repository's public representation exposes only
whether a credential is attached.

### Decision: the built-in repository is a seeded, immutable row

The migration inserts `carverauto/serviceradar` with `builtin: true`, `is_default: true`, and the
two `serviceradar-first-party-*` keys currently in `config.exs:299-302`. Update and destroy actions
reject `builtin: true` rows except for toggling `enabled`.

This is what buys the single code path: after the migration, *every* import — foreground LiveView
action and `FirstPartySyncWorker` alike — resolves a `PluginRepository` struct and reads its keys,
rather than branching on "configured default or user-added". The config keys degrade to seed inputs.

**Alternative considered**: keep the built-in in config and merge it into the dropdown at render
time. No seed migration, but then two shapes flow into the importer and the built-in cannot be
disabled from the UI.

**Idempotency:** the seed keys on `repo_url`, so a re-run or a deployment that already set
`SERVICERADAR_FIRST_PARTY_PLUGIN_REPO_URL` to something else does not produce a duplicate row.

### Decision: `plugins.repositories.manage` is a new admin-only permission, not implied by `plugins.stage`

Staging a package means "import this artifact from a source the platform already trusts". Adding a
repository means "this source is now trustworthy" — it defines the trust anchor that staging is
checked against. Folding the second into the first would let anyone who can import a plugin also
decide what counts as a verified plugin.

Enforcement is in two places on purpose: the LiveView gates the UI affordances, and an Ash policy on
the resource gates the write regardless of caller, following `ServiceRadar.Plugins.Policies` and the
existing `{ActorHasPermission, permission: ...}` check (`policies/checks.ex:256-290`).

### Decision: per-repository auth headers stop at the redirect boundary

Private release assets require the API endpoint
`GET /repos/{owner}/{repo}/releases/assets/{id}` with `Accept: application/octet-stream`, which
responds `302` to a pre-signed URL on `objects.githubusercontent.com`. That pre-signed URL carries
its own authorization; forwarding the `Authorization: Bearer <PAT>` header to it both breaks the
request and discloses the PAT to a host that has no business seeing it.

The existing `auth_host?/1` (`first_party_release_client.ex:517-522`) already restricts auth headers
to `github.com` and `api.github.com`, so the redirect target is excluded today. This decision is to
**keep that invariant while making the token per-repository**, and to cover it with a test rather
than leaving it as an accident of the host list.

## Risks / Trade-offs

- **A third-party repository is remote code execution by design.** Mitigation: signature required and
  non-optional; the existing staged-import review with capability diff still applies to every
  package from every repository; the repository add action is admin-only and audited.
- **A PAT is a broad credential.** GitHub fine-grained PATs can be scoped to a single repository with
  read-only Contents. Mitigation: document that scope as the expectation in the modal's help text;
  never log or audit the token value; resolve it only at fetch time.
- **Seed migration versus an operator who already overrode `SERVICERADAR_FIRST_PARTY_PLUGIN_REPO_URL`.**
  Mitigation: seed keyed on `repo_url`, and the override continues to be read as the seed value.
- **`FirstPartySyncWorker` now iterates N repositories**, so one unreachable private repo could stall
  or fail the whole sync. Mitigation: per-repository isolation — a failing repository records its
  error on the row and does not prevent the others from importing.
- **Verification regression risk.** The change moves trusted keys from a global map to a per-row
  value; a bug there would silently widen what verifies. Mitigation: a test that a bundle signed by
  repository A's key is rejected when imported through repository B.

## Migration Plan

1. Migration creates `platform.plugin_repositories` and seeds the built-in row from current config
   values, keyed on `repo_url` for idempotency.
2. Importer and verification read the repository row; config keys remain as seed inputs so an
   existing deployment's behaviour is unchanged on upgrade.
3. UI switches from text input to dropdown + modal.

Rollback is the inverse migration; because the built-in row is seeded from config and nothing else
depends on the table, dropping it restores the previous single-source behaviour.

## Open Questions

- Should a repository be able to opt into the OCI/cosign path with its own registry host and cosign
  key? The schema leaves room (`artifact_mode`), but nothing in the driving use case needs it, so
  this change does not build it.
- Should a disabled repository's already-imported packages be revoked, or left approved and simply
  not refreshed? This proposal leaves them approved — disabling a source stops future imports and is
  not by itself a statement that past artifacts are bad.

## Decision: publishing tooling lives in the NPM CLI, not in the SDKs

Third-party publishers need tooling for the parts of the contract they cannot reasonably hand-roll:
a deterministic bundle zip whose digest is stable across builds, the canonical-JSON payload the
ed25519 signature covers, the `.sig` document, the release index, and keypair generation (which
exists nowhere today — `build/wasm_plugins/upload_signature_tool.go` has `sign`, `verify` and
`public-key`, but no `keygen`).

That tooling goes into `@carverauto/serviceradar-cli` (`js/cli`), alongside the `plugin` group added
by `add-cli-plugin-publish`. Not into `serviceradar-sdk-go` or `serviceradar-sdk-rust`.

The reason is that publishing is an authentication and packaging concern, not a language one: it
acts on an already-built `plugin.wasm` plus `plugin.yaml`. The expensive part — RFC 8628 device-code
login, per-instance credential storage, TLS CA handling — exists exactly once, in the CLI. Adding a
CLI to each SDK would mean implementing that twice more, and would leave two implementations of
canonical JSON and deterministic zipping that must agree byte-for-byte forever; when they drift, the
symptom a third party sees is `invalid_signature` at import with no further diagnostic. The SDKs stay
libraries, which is what a plugin author imports; they participate through `plugin init` templates.

**Parity is still a live concern and is handled explicitly.** Canonical JSON is already implemented
twice — in the Go signer and in the Elixir verifier (`UploadSignature.verification_payload/2`) — and
the CLI makes three. The arbiter is the Elixir verifier, so the requirement is that every signer
match *it*. Mitigation: a conformance corpus of manifests with expected canonical bytes and expected
signatures for a fixed test key, asserted by the Elixir, Go and CLI test suites alike. The two SDK
repos already mirror `fixtures/` and `testdata/` byte-for-byte, so the convention exists.

**Sequencing note.** `add-cli-plugin-publish` lands first and covers the development loop: a
developer pushes a build straight to an instance they are authenticated against, with no key
material, no GitHub repository and no release index. This change covers distribution: a catalog many
installs subscribe to and re-sync. The `bundle_url` index path this change depends on has no
producer anywhere in the repo today (`scripts/generate-wasm-plugin-import-index.sh` emits `oci_ref`
entries only), so the CLI's `index` command will be its first, and the end-to-end import through a
user-added repository is the first real exercise of that path.
