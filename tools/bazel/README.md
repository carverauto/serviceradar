# Bazel tooling helpers

This directory houses the repository-local Bazel wrapper used by automation and
developer workflows.

- [`bazel`](/home/mfreeman/serviceradar/tools/bazel/bazel): Runs from the repo
  root, prefers `bazelisk`, falls back to `bazel`, and picks up
  `.bazelversion`, `.bazelrc`, and workspace-relative paths.

Use this wrapper when you want Bazel version selection to come from the
repository instead of the ambient machine configuration.
