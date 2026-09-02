# Publishing ServiceRadar Releases with GitHub Actions and Bazel

ServiceRadar releases are published to the CarverAuto Harbor registry and
GitHub Releases. Tag-gated package, image, native add-on, Wasm plugin, and
security workflows live under `.github/workflows/` and run on in-cluster ARC
runners (`serviceradar-signing` for publish/sign, `arc-runner-set` for lint
and checks). The supported workflow is tag gated: a `v*` tag starts the
image/package release together with the native add-on, Wasm plugin,
source-security, and image-security workflows.

The primary workflow is `.github/workflows/release.yml`. It:

1. Validates the tag, `VERSION`, and staging ancestry. Changelog validation is
   performed by `scripts/cut-release.sh` before the tag is published.
2. Builds or verifies all release images and their immutable digests.
3. Signs and verifies the image set, then packages and publishes the Helm chart.
4. Creates or updates a draft GitHub release and uploads packages, the managed
   agent archive, and its signed manifest.
5. Waits for the native add-on and Wasm plugin catalog indexes plus the source
   and image security bundles from the parallel tag workflows.
6. Publishes the GitHub release only after every required asset exists.
7. Advances `demo/prod-release` after publication so the reviewed manual Argo
   rollout can use the verified semver tag.

`.github/workflows/native-addons.yml`, `.github/workflows/wasm-plugins.yml`,
`.github/workflows/source-security.yml`, and
`.github/workflows/image-security.yml` run for the same tag. A release must
stay draft until both catalogs and both security bundles have arrived. This
ordering matters when GitHub immutable releases are enabled because a late
asset upload to an already-published release is rejected.

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

The tag starts five release workflows:

- `Publish Release Artifacts`
- `Publish Native Add-ons`
- `Publish Wasm Plugins`
- `Source Security Scan`
- `Image Security Scan`

The main release must remain draft if a catalog or security workflow fails, or
if one of its required assets does not arrive before the bounded finalization
deadline. Resolve and rerun the failed workflow instead of publishing a
partial release.

## Required Release Outputs

Before the GitHub release becomes public, verify that it contains:

- all expected `.deb` and `.rpm` packages
- `serviceradar-agent_<version>_linux_amd64.tar.gz`
- `serviceradar-agent-release-manifest.json`
- `serviceradar-agent-release-manifest.sig`
- `serviceradar-native-addon-index.json`
- `serviceradar-wasm-plugin-index.json`
- `serviceradar-source-security.tar.gz`
- `serviceradar-image-security-v<version>.tar.gz`
- a `.pkg` when the release was configured to require the macOS package

The image workflow verifies every repository declared in
`docker/images/image_inventory.bzl`. The current contract covers 16 image
repositories and requires the release tag and `latest` to match the immutable
`sha-<commit>` digest before and after publishing. Signatures are verified
before release finalization.

For an additional operator check:

```bash
make verify_publish VERIFY_TAG="v$(cat VERSION)"
```

For releases that touch sync streaming, ResultsRouter, identity reconciliation,
sweep ingestion, mapper promotion, or Armis ingestion, also run the large
ingestion gate against an isolated CNPG test database before tagging:

```bash
scripts/validate-large-ingestion.sh
```

## Demo Handoff

Successful stable, non-draft publication advances `demo/prod-release` and updates
`helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml` to the semver
image tag. Automated Argo sync and Image Updater are intentionally disabled
while the live generated-secret, CNPG, and deployment drift is under review.

Do not patch `global.imageTag` directly for a formal release. Follow
`.agents/skills/release-cut-and-demo-roll/SKILL.md`: verify the release branch,
review every OutOfSync resource, perform a non-pruning manual sync through an
authenticated Argo context, and wait for `Synced|Healthy|Succeeded` with the
key workloads on `v<version>`.

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

Wasm plugin recovery is GitHub Actions: rerun **Publish Wasm Plugins** at the
release tag (`runs-on: serviceradar-signing`). `make push_all_release` covers
container images and Wasm plugins only; it does not publish the Helm chart,
packages, managed-agent manifest, or native add-on catalog, so it must not be
treated as a complete formal release.

Keep the GitHub release draft until all package, image, native add-on, Wasm,
and security verification succeeds. Never work around a failed parallel asset
upload by publishing the draft first; immutable-release enforcement will
prevent the missing asset from being attached afterward.
