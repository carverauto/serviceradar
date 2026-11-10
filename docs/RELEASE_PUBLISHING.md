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
2. Builds or verifies all release images and their immutable digests.
3. Signs and verifies the image set, then packages and publishes the Helm chart.
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
2. Signs the file with `cosign sign-blob` through `cosign_sign_blob_to_files`
   and writes the bundle. The transparency-log setting is the one the image,
   native add-on and Wasm plugin signers use: `COSIGN_TLOG_UPLOAD`, which
   defaults to `true`, so the signature is recorded in Rekor and the bundle
   carries the log entry.
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

The image workflow verifies every repository declared in
`docker/images/image_inventory.bzl`. The current contract covers 16 image
repositories and requires the release tag and `latest` to match the immutable
`sha-<commit>` digest before and after publishing. Signatures are verified
before release finalization.

For an additional operator check:

```bash
make verify_publish VERIFY_TAG="v$(cat VERSION)"
```

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

- Harbor robot credentials (`HARBOR_ROBOT_USERNAME` / `HARBOR_ROBOT_SECRET`)
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
release tag (`runs-on: serviceradar-signing`). `make push_all_release` covers
container images and Wasm plugins only; it does not publish the Helm chart,
packages, managed-agent manifest, or native add-on catalog, so it must not be
treated as a complete formal release.

Keep the GitHub release draft until all package, image, native add-on, Wasm,
and security verification succeeds. Never work around a failed parallel asset
upload by publishing the draft first; immutable-release enforcement will
prevent the missing asset from being attached afterward.
