# Forgejo Actions (retired publisher)

Forgejo is no longer the release publisher. Publish and sign workflows live
in `.github/workflows/` and run on in-cluster ARC (`serviceradar-signing`).

Lint/check gates already live under `.github/workflows/` (`arc-runner-set`).
Do not add new files here.

BuildBuddy / Bazel still own the heavy suites that used to live as Forgejo
jobs (`main.yml`, `rust-musl.yml`, `rust-tests-addon-interop.yml`,
`banner-grab-large.yml`). Those YAML leftovers are not GitHub Actions.
