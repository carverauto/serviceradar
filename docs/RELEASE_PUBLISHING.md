# Publishing ServiceRadar Releases with GitHub Actions and Bazel

ServiceRadar releases are published to the CarverAuto Harbor registry and
GitHub Releases. Tag-gated package, image, native add-on, Wasm plugin, and
security workflows live under `.github/workflows/` and run on in-cluster ARC
runners (`serviceradar-signing` for publish/sign, `arc-runner-set` for lint
and checks). The supported workflow is tag gated: a `v*` tag starts the
image/package release together with the native add-on, Wasm plugin and
source-security workflows. Image security starts after publication produces
the images and draft release, so a delayed publisher cannot exhaust its wait.

The primary workflow is `.github/workflows/release.yml`. It:

1. Validates the tag, `VERSION`, and staging ancestry. Changelog validation is
   performed by `scripts/cut-release.sh` before the tag is published.
2. Builds or verifies all release images and their immutable digests in the disposable build project.
3. Signs and verifies the build image set, promotes its complete OCI dependency
   graph into the protected project, verifies the protected signatures, then
   packages and publishes the Helm chart.
4. Creates or updates a draft GitHub release and uploads packages, the managed
   agent archive, and its signed manifest.
5. Dispatches image security for the same release tag if its bundle is missing,
   then waits for the native add-on and Wasm plugin catalog indexes plus both
   security bundles.
6. Publishes the GitHub release only after every required asset exists.
7. Advances `demo/prod-release` after publication so `serviceradar-demo-prod`
   can sync the verified release commit.

`.github/workflows/native-addons.yml`, `.github/workflows/wasm-plugins.yml`,
`.github/workflows/source-security.yml`, and the dispatched
`.github/workflows/image-security.yml` run for the same tag. A release must
stay draft until both catalogs and both security bundles have arrived. This
ordering matters when GitHub immutable releases are enabled because a late
asset upload to an already-published release is rejected.

The three Bazel-backed publishers (`release.yml` package job,
`native-addons.yml`, and `wasm-plugins.yml`) validate the committed
`MODULE.bazel.lock` in strict mode before they publish: each runs
`bazel mod deps --lockfile_mode=error` and passes `--lockfile_mode=error` to its
release Bazel commands, so a stale dependency lockfile fails the release
instead of being silently regenerated. Fix it with
`bazel mod deps --lockfile_mode=update`, commit the lockfile, and cut a new
release commit.

## Harbor publication boundary

Image, native add-on and Wasm publishers use `scripts/ci/harbor-publish.py`.
The build robot can push only `serviceradar-builds` and can read protected base
images. A separate promotion robot reads builds and writes `serviceradar`.
No deployment or import index is published with disposable image references.
Release tag checks, signing and pre-promotion verification read the build
project; the protected copy is verified again after promotion. Image security
scans protected images with a separate read-only robot.

Setup downloads the shared GitOps promotion tool from an OCI artifact pinned by
manifest digest and checks its file checksum. Keep that protected tooling
artifact for as long as any supported workflow references its digest. Updating
the tool requires reviewing both pins in the helper; no floating tool tag is
executed. The current helper is copied into the job's private temporary directory
before release retries check out an older commit.
Release setup also snapshots the chart helper and the SHA-pinned PyYAML package
already declared in `MODULE.bazel`. Chart validation parses rendered YAML with
the safe loader, including image fields in lists and multiple documents.
Setup records which inventory repositories feed chart digest defaults, and the
chart pins only those repositories present in the release commit's inventory.

Before uploads and promotion, the shared tool requires fresh registry capacity
metrics and less than 85% physical-volume usage. Harbor project quotas are a
separate backstop. Missing metrics, failed source copies, missing architecture
children, missing signatures or quota errors fail publication. The build
and promotion credentials live in separate temporary Docker configs and are
removed by the final cleanup step.

Every tag a publish asks for (`sha-<commit>` and the release tag) must name one
build manifest; promotion refuses tags that disagree. The native add-on and Wasm
publishers therefore push each bundle once, with all of its tags in a single
`oras push`. Each `oras push` stamps its own `org.opencontainers.image.created`
time, so one push per tag yields different digests. Build-project tags are
mutable, so a retry overwrites them rather than keeping a stale artifact.

Promotion copies each root with its platform manifests and blobs, plus the
root's classic Cosign `.sig` tag. When the protected project already holds a
`.sig` tag for that digest, promotion reuses it and does not copy the build
signature. Other build referrers, such as stale signatures and Harbor-generated
SBOMs, are not promoted; the protected project generates its own SBOMs. Helm
chart bundles are not Cosign-signed and are promoted with `--unsigned`.
Protected `.sig` tags must be immutable before these workflows are enabled.
Signature verification remains mandatory before and after promotion. Fixed
protected tags are never replaced with a different digest; `latest` is updated
only after the entire bundle has passed availability checks.
An inventory `static_tags` entry that already exists in the protected project
keeps its existing image; it is created on the promoted digest only when absent.
The successful receipt records verified root digests and tags in `published`,
separate from accessory artifacts, for chart packaging. It lists only the tags
that point at the promoted digest, so a retained static tag is omitted.
Publication verification fails if no trusted Cosign verification identity can
be resolved; finding signature attachment layers alone is insufficient.

Each promotion retains a separate JSON receipt under `receipts/`, while
`receipt.json` remains the latest receipt used by chart assembly. The publisher
workflows upload only those receipt JSON files as `harbor-promotion-` artifacts
identified by workflow, job, run ID and run attempt, before removing credentials.
Image and chart receipts are both retained. Missing receipts fail the upload;
cleanup still runs if the upload fails. Receipts retained from a failed run are
diagnostic evidence only: deployment requires a successful run with mandatory
signature verification before and after promotion.

### Images built outside Bazel

Two kinds of image are published one at a time, never by a release, and only when
listed in `docker/images/image_inventory.bzl`:

- `DOCKERFILE_IMAGES`, built from a Dockerfile by `publish-dockerfile-image.yml`
  and signed with `SERVICERADAR_DOCKERFILE_IMAGE`;
- `NATIVE_BUILD_IMAGES`, assembled with crane around a binary built natively on a
  credential-less runner and signed with `SERVICERADAR_NATIVE_IMAGE`. The list is
  currently empty.

The Dockerfile workflow resolves the published tag. A native workflow passes
the verified build digest directly through signing and promotion. Both use the same
`sign-oci-publish.sh` path and OpenBao role as `publish-oci.yml`, and are
promoted like any other image. The Dockerfile workflow publishes only from
`staging`.

### Publishing the promotion tool

`scripts/ci/harbor-publish.py` pins the shared promoter
(`carverauto/gitops` `k8s/harbor/promote-artifacts.py`) as
`registry.carverauto.dev/serviceradar/harbor-lifecycle-tools@<digest>` plus the
file's SHA256. The **Publish Harbor Lifecycle Tools** workflow
(`publish-harbor-lifecycle-tools.yml`) publishes a new promoter with the same
build and promotion robots as the other publishers. Its inputs are the GitOps
commit, the file's reviewed SHA256, the file as base64 (the GitOps repository is
private and no workflow credential can read it), a fixed creation time, and an
optional expected digest. The bundle is built in a local OCI layout with fixed
annotations, so its digest depends only on those inputs. A mismatch with the
expected digest fails before any registry write. The workflow pushes the bundle
to build storage, promotes it with the new promoter itself, and tags it
`sha-<gitops commit>`. If that tag already resolves to the produced digest, the
run verifies it and writes nothing; a tag holding other bytes fails. The
dispatch command is in the workflow header. Update the pin in
`harbor-publish.py` only after the run succeeds.

The separate GitOps rollout gate still controls retention activation: do not
enable disposable deletion until all deployment paths reject that project and
the build/promotion/rollback and retention dry-run exercises pass.

## Prepare Release Metadata

Update the top `CHANGELOG` entry and `VERSION` before cutting the release. Use
the release helper for all release commits and tags:

```bash
scripts/cut-release.sh --version 1.4.10 --dry-run
```

The dry-run validates the version, changelog, tag shape, existing local tag,
Helm metadata changes, and the release branch operation without creating refs.
It reports the remote-tag check that the real cut will perform but does not
contact the remote itself.

For prerelease series, use dot-separated numeric identifiers such as
`1.4.10-pre.1`, `1.4.10-pre.2`, and `1.4.10-pre.10`. Native add-on sync uses
strict SemVer precedence to prevent release downgrades: numeric identifiers
sort numerically, while legacy `pre10` and `pre2` identifiers sort as text
(`pre10` precedes `pre2`). Existing release tags are not reinterpreted.

## Cut and Push the Release Branch

Run the real cut from a clean feature/release branch, never directly from
`staging`:

```bash
scripts/cut-release.sh --version 1.4.10 --push
```

`--push` publishes only the current branch with an explicit branch refspec. It
leaves the annotated tag local because the release workflow rejects tags whose
commit is not yet reachable from `origin/staging`.

Open the branch with `gh`, let CI pass, and merge it with an ancestry-preserving
merge commit:

```bash
gh pr merge <PR> --merge
```

Do not squash or rebase the release PR because that changes or discards the
tagged commit. After the merge, refresh the remote staging ref and prove tag
ancestry before publishing the tag:

```bash
git fetch origin refs/heads/staging:refs/remotes/origin/staging
git merge-base --is-ancestor 'v1.4.10^{commit}' \
  refs/remotes/origin/staging && \
  git push origin refs/tags/v1.4.10:refs/tags/v1.4.10
```

Do not combine the branch and tag in one push. Without `--push`, the helper
prints the explicit release-branch push, ancestry check, and tag-push commands
for the operator to run.

## Monitor GitHub Actions

Use the repository's authenticated `gh` client:

```bash
gh run list --repo carverauto/serviceradar --branch v1.4.10
gh release view v1.4.10 --repo carverauto/serviceradar
```

The tag starts four release workflows:

- `Publish Release Artifacts`
- `Publish Native Add-ons`
- `Publish Wasm Plugins`
- `Source Security Scan`

Publication dispatches `Image Security Scan` for the same tag once the images and draft release exist.

The main release must remain draft if a catalog or security workflow fails, or
if one of its required assets does not arrive before the bounded finalization
deadline. Resolve and rerun the failed workflow instead of publishing a
partial release.

## Required Release Outputs

Before the GitHub release becomes public, verify that it contains:

- all expected `.deb` and `.rpm` packages
- `serviceradar-agent_<version>_linux_amd64.tar.gz`
- `SHA256SUMS`, its signature `SHA256SUMS.sigstore.json`, and one
  `<asset name>.sha256` sidecar for every `.deb`, `.rpm`,
  `.pkg`, `.msi` and agent runtime `.tar.gz` (see
  [Release Checksums](#release-checksums))
- `serviceradar-agent-release-manifest.json`
- `serviceradar-agent-release-manifest.sig`
- `serviceradar-native-addon-index.json`
- `serviceradar-wasm-plugin-index.json`
- `serviceradar-source-security.tar.gz`
- `serviceradar-image-security-v<version>.tar.gz`
- the signed macOS ARM64 `.pkg` and its provenance JSON when the macOS
  job succeeds. If that job fails, is cancelled, or is skipped, publication
  proceeds without the macOS installer; the other required assets still gate
  finalization.

### Release Checksums

`//build/release:publish_packages` writes the checksum files in the same
process that uploads the packages. It hashes each file from the path it is
about to upload: the Bazel outputs for Linux packages and runtime archives, and
the handoff files for the macOS and Windows installers, after their bytes have
been checked against their provenance. Nothing is downloaded again to compute a
checksum.

| Asset | Contents |
| --- | --- |
| `<asset name>.sha256` | One `sha256sum` line, `<hex digest>  <asset name>`, for one `.deb`, `.rpm`, `.pkg`, `.msi` or agent runtime `.tar.gz` |
| `SHA256SUMS` | The same line for every one of those files and for each installer's `.provenance.json`, sorted by name |
| `SHA256SUMS.sigstore.json` | Sigstore bundle with the Cosign release key's signature over `SHA256SUMS` |

The sidecar name is a contract with installers that discover a release. The
`serviceradar-ansible` agent role looks for an asset named exactly
`<package name>.sha256` and passes its URL to `get_url` as
`checksum: sha256:<url>`. `get_url` accepts `sha256sum` lines and selects the
one whose filename equals the last path segment of the package URL, so the
filename inside the sidecar must stay the published asset name.

The publisher refuses to continue in three places:

1. Before the draft release is created or changed, it signs `SHA256SUMS`,
   hashes every file in the upload plan a second time and requires a matching
   `SHA256SUMS` line, plus a matching sidecar for each installable. A file
   type with no checksum rule is refused, so a new kind of asset cannot be
   added without one. A missing or empty signature bundle, a signer that
   fails, and a signer that changes `SHA256SUMS` are refused too.
2. After the uploads, it reads the release back and requires each planned file
   to be stored exactly once. Where GitHub reports a digest of the stored
   bytes, that digest must equal the local one.
3. The `Verify uploaded release assets via GitHub API` step requires
   `SHA256SUMS`, `SHA256SUMS.sigstore.json` and a non-empty sidecar for every
   installable on the draft.

A failure in any of them leaves the release as a draft.

`serviceradar-agent-release-manifest.json` and its `.sig` are not listed in
`SHA256SUMS`. The manifest is written after the runtime archives are uploaded,
carries their SHA256 digests, and is signed with the agent release key. The
catalog indexes and security bundles are attached by other workflows and have
no checksum files.

#### Checksum signature

`SHA256SUMS` is signed with the same Cosign release key as the container
images (`hashivault://cosign-release` in OpenBao Transit; public half in
`docs/cosign.pub`). No other key or secret is involved.

The publisher is given `--checksums_signer scripts/sign-release-checksums.sh`.
After it has written `SHA256SUMS`, it runs that script on the file it will
upload. The script:

1. Logs in to OpenBao with `scripts/ci/prepare-openbao-cosign-env.sh`. The
   login is inside the script because the publisher is started by `bazel run`
   and the 20-minute token would expire while the packages build.
2. Records the file's SHA-256 in the job's signing ledger, signs the file with
   `cosign sign-blob` through `cosign_sign_blob_to_files` and writes the bundle,
   then records the returned log entry in the ledger. `COSIGN_TLOG_UPLOAD`
   defaults to `true`, so the signature is recorded in Rekor and the bundle
   carries the log entry. Unlike the image, native add-on and Wasm signatures,
   this is a protobuf Sigstore bundle, logged through the TUF signing config.
3. Verifies the bundle with `cosign verify-blob` and the committed
   `docs/cosign.pub`, then unsets the OpenBao token.

A release whose `SHA256SUMS` cannot be signed and verified uploads nothing. A
dry run (`dry_run: true`) does not call the signer and needs no signing
credentials; it plans a placeholder in place of the bundle.

Each run signs again, and the bundle bytes differ between runs. A retry of a
draft therefore replaces `SHA256SUMS.sigstore.json`, which requires
`overwrite_assets` to stay `true` (the default).

To verify a published release:

```bash
cosign verify-blob \
  --key https://raw.githubusercontent.com/carverauto/serviceradar/staging/docs/cosign.pub \
  --bundle SHA256SUMS.sigstore.json \
  SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
```

The sidecars are not signed separately. Their lines also appear in the signed
`SHA256SUMS`.

The image workflow verifies every repository in `PUBLISHABLE_IMAGES` in
`docker/images/image_inventory.bzl` (`DOCKERFILE_IMAGES` and `NATIVE_BUILD_IMAGES`
are never published by a release). It requires the release tag and `latest` to match the immutable
`sha-<commit>` digest before and after publishing. Signatures are verified
before release finalization.

For an additional operator check:

```bash
make verify_publish VERIFY_TAG="v$(cat VERSION)" SIGNING_LEDGER=<signing-ledger artifact>
```

The ledger is the one the signing run attached to the draft release (see
"Transparency-log receipts and the signing ledger" below).

For releases that touch sync streaming, edge-record ingestion, identity
reconciliation, sweep ingestion, mapper promotion, or Armis ingestion, also run
the large ingestion gate before tagging. The script runs
`//elixir/serviceradar_core:large_ingestion_release_gate` under a run id whose
database was provisioned with
`//rust/integration-db:provision_generation_large_ingestion` (see the SRQL
fixture lifecycle in `docs/agent-runbooks.md`):

```bash
SERVICERADAR_INTEGRATION_RUN_ID=<run id> scripts/validate-large-ingestion.sh
```

## Demo Handoff

`scripts/cut-release.sh` writes `global.imageTag` in
`helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml` to the release
tag on the release commit. When that file exists,
`scripts/validate-release-metadata.sh` fails unless `global.imageTag` equals
the release tag. `.github/workflows/release.yml` runs that check in its
release-source steps, before publication. A missing file is allowed.
Successful stable, non-draft publication then advances `demo/prod-release` to
that commit.

`serviceradar-demo-prod` tracks the branch and syncs it automatically, with
prune and self-heal off. Image Updater stays disabled. Do not patch
`global.imageTag` on the live Application. Rollout checks are in
`.agents/skills/release-cut-and-demo-roll/SKILL.md`.

## CI Prerequisites

The GitHub `release` environment must provide:

- Build robot credentials (`HARBOR_BUILD_ROBOT_USERNAME` / `HARBOR_BUILD_ROBOT_SECRET`)
- Promotion robot credentials (`HARBOR_PROMOTION_ROBOT_USERNAME` / `HARBOR_PROMOTION_ROBOT_SECRET`)
- Read-only protected robot credentials for image security (`HARBOR_READ_ROBOT_USERNAME` / `HARBOR_READ_ROBOT_SECRET`)
- BuildBuddy credentials used by remote Bazel builds
- the release signing identity and OpenBao Transit access (in-cluster
  `github-signing-runner` Kubernetes auth)
- the managed-agent Ed25519 release key
- Wasm upload signatures come from OpenBao Transit (`plugin-upload-signing`),
  not a long-lived private key in Actions secrets

Do not print these values or URLs containing embedded credentials. The
`serviceradar-signing` runner label is reserved for signing/publishing work;
catalog finalization should not hold that runner while waiting for parallel
workflows.

## Recovery

After a transient publish failure, rerun the failed release jobs; never delete
and recreate the tag. Once publication succeeds, the image-security dispatch
job starts the scan if its bundle is still missing. If the scan itself fails,
rerun **Image Security Scan** for that same tag first, then rerun the failed
release jobs. A successful uploaded bundle is preserved on retry. The macOS
build remains an optional publish dependency: its failure must not prevent
the successful Linux/image and Windows artifacts from being published.

Wasm plugin recovery is GitHub Actions: rerun **Publish Wasm Plugins** at the
release tag (`runs-on: serviceradar-signing`). `make push_all_release` and
`make push_wasm_plugins` are retired: they exit without publishing anything.

Keep the GitHub release draft until all package, image, native add-on, Wasm,
and security verification succeeds. Never work around a failed parallel asset
upload by publishing the draft first; immutable-release enforcement will
prevent the missing asset from being attached afterward.

### One signature format: classic Cosign `.sig` tags

Images, native add-ons and Wasm plugins carry exactly one signature format: the
classic Cosign `.sig` tag (`sha256-<digest>.sig`). Demo admission (the Kyverno
`verify-serviceradar-images` policy, key-based `verifyImages`) reads only this
format, and a digest whose only signature is a Sigstore bundle referrer is
denied with `no signatures found`. The signers therefore never run
`cosign sign`, which under cosign v3 writes a bundle referrer. The verifiers run
`cosign verify --new-bundle-format=false` so that they check the same signature
admission checks; cosign v3 otherwise prefers a bundle referrer.

Each digest is signed once. Before signing, the shared helper
(`scripts/reconcile-legacy-signature.py`) looks for an existing `.sig` tag in
the protected project and then in the build project. Reuse requires matching
manifest and blob hashes, a valid detached signature on every layer under the
configured key, and the exact image digest and repository identity. The verifier
accepts 1 through 32 signature layers; this is its operational safety cap, not a
Cosign format limit. Repeated payload digests do not skip any signature check, and
the original manifest and layer order are preserved. An attachment signed in
either the protected or build project is valid for that same repository; another
registry, project, or repository is refused.

A verified protected signature is reused: it is copied into the build project
only when the build project has no `.sig` tag for the digest, so pre-promotion
verification finds it. A build `.sig` tag that differs from the protected one
(a byte-identical rebuild signed earlier) is kept if it verifies, and promotion
keeps the protected signature without copying the build one. The protected tag
is never replaced. Only when no verified signature exists is a new one created.

Configured signing-key lookup failures and unsupported keyless legacy reuse fail
closed. An existing signature that no longer verifies under the current key
requires an explicit trust/key-rotation decision. The signers do not fall back to
an adjacent stale public key when exporting a configured signing key fails.
Release retries snapshot this helper with the reviewed signer and Cosign common
code before checking out an older release; the release public key still comes
from the explicit release checkout, and the pinned Rekor keys come with the
snapshot (`SERVICERADAR_SIGSTORE_DIR`).

### Transparency-log receipts and the signing ledger

Every new classic `.sig` carries its Rekor receipt. The shared signer
(`attach_legacy_signature` in `scripts/cosign_common.sh`) signs with
`cosign sign-blob --use-signing-config=false --new-bundle-format=false
--rekor-url https://rekor.serviceradar.cloud --tlog-upload=true`, so the entry is
written to ServiceRadar's self-hosted Rekor v1 log and never to a log that a
TUF-delivered signing config names. The legacy bundle's `rekorBundle` (the
SignedEntryTimestamp and the logged `body`, `integratedTime`, `logIndex` and
`logID`) becomes the `dev.sigstore.cosign/bundle` annotation on the one
`simplesigning` layer, next to `dev.cosignproject.cosign/signature`. That is the
annotation `cosign sign` itself writes. The tag, media types and layer count do
not change, and Kyverno and promotion read the same `.sig` as before. Signing
fails, and no `.sig` tag is written, when the upload returns no
SignedEntryTimestamp or a log ID other than that of `docs/sigstore/rekor.pub`.
Release signing therefore stops while the self-hosted Rekor (or its OpenBao
Transit token) is down. Nothing at verification time depends on it.

Each signing job writes a signing ledger (`SERVICERADAR_SIGNING_LEDGER`, one JSON
line per event, written by `scripts/cosign_receipt.py`):

- `sign`: written before a signature is uploaded, with the subject
  (`repo@digest`, or `SHA256SUMS`), the payload SHA-256, the workflow, job, run
  ID and attempt, and the time.
- `logged`: after the upload, adding the log index, integrated time, log ID and
  entry UUID (the RFC 6962 leaf hash of the logged body).
- `reused`: an existing verified signature was reused instead of signing.

Every release-key signing workflow (`release.yml`, `publish-oci.yml`,
`wasm-plugins.yml`, `native-addons.yml`, `external-wasm-plugin.yml`,
and `publish-dockerfile-image.yml`) uploads its ledger with `if: always()` as the
artifact `signing-ledger-<workflow>-<job>-<run id>-<attempt>`, retained 90 days.
Tag runs also attach it to the draft GitHub release
(`scripts/ci/attach-signing-ledger.sh`).

Release verification (`cosign_verify_legacy_signature`, used by the three
`verify-*-publish.sh` scripts before and after promotion) classifies each digest
from the ledger, never from whether a receipt is present:

- Created in this run: the receipt is required. The verifier reads `logID` from
  the annotation, selects `docs/sigstore/rekor-keys/<logID>.pub`, and runs
  `cosign verify --new-bundle-format=false --offline=true --key <release key>`
  with that file as `SIGSTORE_REKOR_PUBLIC_KEY`, and with no `--trusted-root` and
  no `--insecure-ignore-tlog`. A missing receipt, a log ID outside the key set, a
  SignedEntryTimestamp that does not verify, or a logged entry that names a
  different signature, key or payload hash fails the release.
- Reused with a receipt from the self-hosted log: verified the same way.
- Reused with a receipt from the public-good log (some images were signed by
  hand before the cutover): verified offline against
  `docs/sigstore/pre-cutover-rekor-keys/`, and accepted only when the receipt
  was integrated before the cutover pinned in `docs/sigstore/cutover.json`
  (the v1.5.8 tag time). That key is never accepted for a signature created in
  the run or at import.
- Reused without a receipt: a Wasm plugin or native add-on digest is verified
  with the release key alone (`--insecure-ignore-tlog=true`) only when it is on
  the frozen pre-cutover allowlist
  (`docs/sigstore/pre-cutover-first-party-digests.json`); otherwise it fails.
  An image is verified with the release key alone; Kyverno remains the
  admission gate for images.
- Not in the ledger: fails.

`make verify_publish` therefore needs the ledger of the run that signed the
images (`SIGNING_LEDGER=<downloaded artifact>`).
