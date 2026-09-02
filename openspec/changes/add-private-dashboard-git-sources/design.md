## Context
The current dashboard Git import path accepts a GitHub repository URL, resolves a ref through the GitHub API, fetches the manifest and renderer from `raw.githubusercontent.com`, and records GitHub verification metadata. This works for public repositories but does not support private GitHub repositories, GitHub Enterprise hosts, or Forgejo/Gitea repositories.

The customer's dashboard package is built from `~/src/example-dashboard` and can be uploaded manually as `dist/manifest.json` plus `dist/renderer.js`, but the desired production workflow is source-driven and repeatable.

## Goals
- Let an admin create a reusable private dashboard Git source.
- Generate a read-only deploy keypair inside ServiceRadar and expose only the public key to the operator.
- Import dashboard package manifests and renderer artifacts from private repositories without exposing repository credentials to browsers, agents, or package manifests.
- Preserve the existing dashboard package validation: manifest schema, renderer digest, route binding rules, size limits, and source metadata.
- Support at least GitHub private repositories initially, with an abstraction that can support Forgejo/Gitea over SSH without rewriting the dashboard package importer.

## Non-Goals
- Do not allow user-supplied private key paste as the primary path.
- Do not expose private Git credentials to the dashboard renderer, agent config, or downloaded package assets.
- Do not require agents to clone Git repositories.
- Do not make dashboard packages auto-update on every branch movement in the initial implementation; imports remain explicit and audited.

## Decisions
- Model a dashboard Git source as an admin-managed resource with repo URL, allowed host fingerprint metadata, encrypted private key reference, public key, created/rotated timestamps, and last connectivity status.
- Generate Ed25519 deploy keys server-side. The UI displays the public key and key label; the private key is encrypted using the existing credential secret path.
- Fetch private repositories from web-ng/core server-side into a temporary work directory using a constrained Git command wrapper or a project-owned Git client module. The wrapper must set `GIT_SSH_COMMAND` to an identity file and known-hosts file owned by the request.
- Require path normalization for manifest and renderer paths and reject absolute paths, parent traversal, symlinks escaping the checkout, and oversized artifacts.
- Resolve refs to immutable commit SHAs before import and store the source commit on the dashboard package.
- Keep verification policy extensible: public GitHub API signature checks continue where available; private SSH imports record source commit and host/key metadata, and may optionally require signed commits when the provider supports verification.

## Risks / Trade-offs
- Stored private keys raise operational risk. Mitigation: generate read-only deploy keys, encrypt at rest, redact in UI/API/logs, audit every use, and support rotation/revocation.
- SSH host verification can be skipped accidentally if implemented with permissive defaults. Mitigation: pin known host keys during source creation/test and fail closed on mismatch.
- Git clones can be expensive. Mitigation: shallow fetch the requested ref, enforce timeouts and artifact size limits, and clean temporary directories after import.
- Private GitHub APIs could be supported with fine-grained tokens, but SSH deploy keys are provider-neutral and satisfy the immediate private repository use case.

## Migration Plan
1. Add the dashboard Git source resource and migrations.
2. Add key generation, storage, public-key display, test connection, rotate, and revoke flows.
3. Add private Git fetch support behind the existing dashboard package importer.
4. Extend the import UI/API to select a source and import by ref/manifest path.
5. Add tests covering private source import, path safety, key redaction, host key mismatch, and route binding.

## Open Questions
- Should the first UI live under Settings -> Dashboard Packages, or under a shared Settings -> Git Sources page reusable by plugin package imports?
- Should production require an explicit host key fingerprint entered by an admin, or allow first-use capture with a warning and audit event?
- Should the source support GitHub App installation tokens later for richer verification metadata?
