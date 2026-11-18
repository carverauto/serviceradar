# Change: Carry the transparency-log receipt in classic signatures and verify it offline

## Why

Up to v1.5.3, first-party Wasm plugins and native add-ons were signed with `cosign sign`, which
also wrote a Sigstore bundle referrer holding the Rekor inclusion proof. The importer read that
bundle and checked the log entry offline. Commit cc4e0917d5 (issue #6619) moved images, add-ons and
Wasm plugins to one classic `.sig` signature per digest, because demo Kyverno key-based
`verifyImages` reads only `.sig`. The signers still run `cosign sign-blob` with transparency-log
upload on, so every signature is logged in public Rekor. The hand-built `.sig` manifest, however,
carries only the `dev.cosignproject.cosign/signature` annotation, and the Rekor receipt is
discarded. From v1.5.4 the importer could confirm the log entry only by an online lookup. An
air-gapped install waited about three minutes per package and then rejected the import.

`verify-first-party-imports-without-sigstore` (#6778, merged) made import verification key-only
(`--insecure-ignore-tlog=true`). Imports work again, but the log check is gone. With key-only
verification, anyone who can produce a signature with the release key can produce an importable
package without a public trace.

This change restores the receipt to the classic signature, verifies it offline at import, and adds
a monitor that watches the log for the release key. Without the monitor, the receipt has no
detection value.

## What Changes

- **Signing (images, native add-ons, Wasm plugins).** Each new classic `.sig` layer carries the
  legacy Rekor bundle in the `dev.sigstore.cosign/bundle` annotation: the SignedEntryTimestamp
  (SET) plus the payload with `body`, `integratedTime`, `logIndex` and `logID`. The three
  duplicated `attach_legacy_signature` implementations become one shared helper. Signing fails if
  Rekor returns no SET, so a signature can never be published without its receipt. The signature
  format stays the same. Kyverno and Harbor promotion read the same `.sig` tag as before.
- **Pinned log.** The signer uploads to the public-good Rekor v1 log through cosign's legacy upload
  path (`--use-signing-config=false`), not to whatever log the TUF-delivered signing config names.
  A Rekor v2 entry has no SET and cannot be expressed in the legacy annotation.
- **Release verification.** The repository verification scripts check the receipt of every
  signature created in the current run offline and fail the release when it is missing or does not
  verify. A reused pre-cutover signature (including a container image's) carries no receipt and is
  exempt from that check; Kyverno remains the admission gate for images.
- **Offline verification at import.** The web-ng image ships the Rekor v1 public key, pinned
  byte-for-byte to a committed copy. `CosignVerifier` verifies the receipt with that key: the SET
  must verify, and the logged body must name the same signature, release public key and payload
  hash. Import never makes a network call to a Sigstore service.
- **Artifacts without a receipt.** All first-party `.sig` signatures published up to the cutover
  release lack the annotation, and Harbor tag immutability prevents adding it. The product owner
  decided on a frozen allowlist of every pre-cutover first-party Wasm plugin and native add-on
  digest, shipped in the web-ng image; those import key-only. From the cutover release on, every
  other first-party Wasm plugin or native add-on digest requires a receipt (design.md,
  Decision 9).
- **Cosign upgrade.** The signer (`scripts/install-cosign.sh`) and the web-ng image
  (`MODULE.bazel`) move together from v3.0.3 to a release with the fixes for
  GHSA-whqx-f9j3-ch6m and GHSA-fx35-mq7g-6g98. GHSA-whqx-f9j3-ch6m (fixed in 3.0.4) lets a
  receipt for an unrelated Rekor entry pass verification on the trusted-root path, which is the
  check this change relies on.
- **Monitoring.** A scheduled GitHub Actions workflow on `arc-runner-set` scans new Rekor v1
  entries for the release key's fingerprint. It alerts on any entry that does not match a payload
  recorded by one of the repository's release-key signing runs, and on its own failure or
  blindness.
- **Pinned-key update process.** The same workflow compares the pinned Rekor key with Sigstore's
  published trusted root and raises an alert when the active Rekor v1 key set changes.

## Non-goals

- No change to the key-only import behaviour from #6778 until this change is implemented and
  released. Until then, #6778 is the contract.
- No Sigstore bundle or OCI-referrer signature format. The 2026-11-15 single-classic-signature
  decision stands.
- No Kyverno policy change. Design.md, Decision 3, shows from the Kyverno v1.17.1 source that the
  annotation lets the existing policy verify offline, without its per-image online lookup.
- No prevention. A receipt and a monitor detect misuse of the key. They do not stop a validly
  logged malicious signature from being imported.
- Third-party plugin repositories are out of scope. They are verified with per-repository
  ed25519 upload signatures, not Cosign (`add-third-party-plugin-repositories`), so there is no
  receipt to require.
- Rekor v2 receipts are out of scope; see Risks in design.md.

## Threat model (summary; full version in design.md)

- **Adds:** from the cutover release on, a first-party Wasm plugin or native add-on accepted at
  import must have a public Rekor record of its signature, unless its digest is on the frozen
  pre-cutover allowlist. A signature made with the release key outside the repository's signing workflows, for
  example by a stolen OpenBao token or an abused Transit role, is publicly detectable. The monitor
  reports it within about an hour. The log is also a third-party-auditable history of everything
  the key signed, which helps the forensics after an incident.
- **Does not add:** prevention, protection against a compromised run of the signing workflow
  itself (its ledger explains its own entries), or protection before the cutover release. Until
  then receipts are optional, and an attacker simply omits one.
- **Likelihood:** low. The key is non-exportable in OpenBao Transit behind a sign-only policy and a
  dedicated signing runner and `release` environment. The practical exposure is abuse of the
  signing oracle, not theft of the key bytes.
- **Complexity cost:** moderate. It touches one shared signer helper, one verifier, a cosign bump,
  a pinned key file with a consistency test, a digest allowlist, a signing ledger and one new
  scheduled workflow. Release signing then depends on public Rekor v1 being up (it does in
  practice today) and stops working when Rekor v1 is frozen.

## Impact

- Affected specs: `artifact-signing` (new), `wasm-plugin-system`, `wasm-plugin-builds`
- Affected code: `scripts/cosign_common.sh`, `scripts/sign-oci-publish.sh`,
  `scripts/sign-native-addon-publish.sh`, `scripts/sign-wasm-plugin-publish.sh`,
  `scripts/verify-*-publish.sh`, `scripts/install-cosign.sh`, `MODULE.bazel` (cosign archives),
  `docker/images/BUILD.bazel` (web-ng image layer for the pinned key),
  `elixir/web-ng/lib/serviceradar_web_ng/plugins/cosign_verifier.ex`,
  `elixir/web-ng/lib/serviceradar_web_ng/plugins/first_party_importer.ex` (verification metadata),
  `.github/workflows/` (new monitor workflow; ledger upload in every release-key signing workflow:
  `release.yml`, `publish-oci.yml`, `wasm-plugins.yml`, `native-addons.yml`,
  `external-wasm-plugin.yml`), `build/ci/scheduled_job_watch.py`,
  `build/contracts/` (new consistency tests)
- Affected docs: `docs/sigstore/README.md`, `docs/RELEASE_PUBLISHING.md`, `docs/agent-runbooks.md`
  (manual demo signing), `docs/docs/wasm-plugins.md`, `docs/docs/native-addons.md`
- Interaction with pending changes: builds on `verify-first-party-imports-without-sigstore` and
  keeps its "no public Sigstore service" requirement. The pending `add-signed-wasm-plugin-import`
  delta still says "Rekor entry" for import. This change makes that wording accurate again, as an
  offline receipt check.
