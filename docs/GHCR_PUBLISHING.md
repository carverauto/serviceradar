# Publishing ServiceRadar artifacts to Harbor

GitHub Actions owns deployable publication. Bazel builds the artifacts; the
publisher uploads into the private `serviceradar-builds` project, signs and
verifies them there, then promotes the exact graph into `serviceradar`.
Deployment references and first-party import catalogs must use protected digests.
Disposable build artifacts can expire and must never become runtime dependencies.

## Supported workflows

- `publish-oci.yml`: reviewed test image builds, with `full` or
  `web-stack-commit-only` scope and an exact `expected_commit`.
- `release.yml`: authorized product release images, digest-pinned Helm bundle,
  and package assets.
- `native-addons.yml`, `wasm-plugins.yml`, `external-wasm-plugin.yml`: signed
  native or Wasm artifacts, promoted before release catalogs are published.

For example, after publishing the reviewed branch:

```bash
gh workflow run publish-oci.yml --repo carverauto/serviceradar \
  --ref <reviewed-branch> -f publish_scope=web-stack-commit-only \
  -f expected_commit=<full-commit>
gh run watch <run-id> --exit-status
```

Require a successful promotion receipt. Its `published` list records each main
repository, digest, and tags; its artifact closure records verified manifests,
platforms, blobs, and attachments. Keep unchanged service digests when rolling a
subset. A successful build upload or a tag lookup alone does not authorize a roll.
See the [test image rollout skill](../.agents/skills/demo-local-rollout/SKILL.md)
and [release guide](../RELEASE.md).

## Credentials and capacity

GitHub stores separate `HARBOR_BUILD_ROBOT_USERNAME/SECRET` and
`HARBOR_PROMOTION_ROBOT_USERNAME/SECRET` pairs. The build identity can push only
to `serviceradar-builds` and read protected base images. The promoter reads builds
and writes protected artifacts. Read-only checks use `HARBOR_READ_ROBOT_*`.

`scripts/ci/harbor-publish.py setup` installs the digest- and checksum-pinned
promotion tool and private Docker configurations. It exports
`HARBOR_LIFECYCLE_DIR` and `HARBOR_PUBLISH_TOOL`, preserved across release checkout.
`build` and `push-images` check fresh physical registry capacity before uploading;
`promote` checks again before verified copying. Missing or stale metrics and the
85% high-water mark fail closed. Low-level artifact publishers and signing
launchers also require this installed capacity tool and refuse protected writes.
Always run `cleanup` after the workflow, including failure paths.

BuildBuddy's registry bootstrap still accepts `HARBOR_USERNAME/HARBOR_TOKEN` for
read access needed by builds and tests, with `OCI_AUTH_REQUIRED=1` when Harbor is
required. It does not grant publication authority. Keep credential values out of
YAML, command arguments, artifacts, and logs.

## Operator entrypoints

`make push_all`, `push_all_release`, `push-web-ng`, `push_wasm_plugins`, the direct
push-and-restart targets, `scripts/push_all_images.sh`, `scripts/build-images.sh --push`, and `//build/buildbuddy:release_pipeline` refuse publication and name the
supported workflow. Local image builds remain available.

Raw Bazel `*_push` targets default to `serviceradar-builds`. They are low-level
upload primitives; use the shared publisher for capacity checks and verified
promotion. Never override them to write directly into the protected project.
Canonical `image_inventory.bzl` repositories remain protected because receipts,
chart generation, and runtime readers consume those names.

For authorized executor or workflow-runner image maintenance, use the scoped
build/promote sequence in [the BuildBuddy runbook](../k8s/buildbuddy/README.md).
It requires the same capacity checks and protected receipt before a consumer pin
changes. No workstation tag-copy or manual protected signature append is needed.

## Verification

The workflow verifies image platforms, runtime metadata, and signatures before
promotion, then verifies protected publication. Customer signature verification
uses [cosign.pub](cosign.pub), or the identity policy and trusted root documented
in [the Sigstore guide](sigstore/README.md). Verify by protected digest, not a
mutable tag. The shared lifecycle tool's closure proof supplements signature
verification; it does not replace the signing trust policy.
