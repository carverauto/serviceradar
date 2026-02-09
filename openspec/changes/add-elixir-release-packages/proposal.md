# add-elixir-release-packages

## Summary

Add Debian and RPM packages for `serviceradar-core-elx` and `serviceradar-agent-gateway` to the Bazel release pipeline so bare-metal deployments include all Elixir services.

## Motivation

GitHub issue #2751: `serviceradar-core-elx` is completely missing from release bundles. Container images are built for all three Elixir services (core-elx, agent-gateway, web-ng) but only web-ng has .deb/.rpm packaging. Bare-metal deployments cannot install core-elx or agent-gateway from release artifacts.

## Scope

- Add `core-elx` and `agent-gateway` entries to `packaging/packages.bzl`
- Create packaging directories with env config, systemd units, and install scripts (mirroring the existing `web-ng` pattern exactly)
- Create Bazel BUILD files that wire into `release_targets.bzl` auto-discovery

No workflow changes needed — `release_targets.bzl` auto-discovers all entries in `PACKAGES` and the release workflow already publishes everything from `//release:package_artifacts`.

## Affected Specs

- `deployment-versioning` (new capability: `release-packaging`)
