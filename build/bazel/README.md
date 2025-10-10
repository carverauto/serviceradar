# Bazel tooling helpers

This directory houses small scripts and wrappers that standardize how the
monorepo interacts with Bazel.

- `bazel`: Delegates to `bazelisk`, ensuring commands run from the repository
  root so they pick up `.bazelversion`, `.bazelrc`, and workspace-relative
  paths. Use it in automation (for example, `./tools/bazel/bazel test //...`).

Add new helpers for common workflows (formatting, query utilities, etc.) as the
migration progresses.
