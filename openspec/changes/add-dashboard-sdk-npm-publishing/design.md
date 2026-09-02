# Design: Dashboard SDK npm Publishing

## Context
The dashboard SDK is intended to be consumed by independent customer dashboard repositories such as `example-dashboard`. Those repositories should install `@serviceradar/dashboard-sdk` from npm and use SDK-owned commands for renderer development and packaging. Keeping publish logic inside each customer dashboard would duplicate CI, token handling, package validation, and release policy.

## Goals
- Publish `@serviceradar/dashboard-sdk` through npm with standard `npm install` semantics.
- Gate SDK changes with tests and `npm pack --dry-run` before merge.
- Publish only from intentional release refs or manual release workflow runs.
- Use npm trusted publishing from the GitHub mirror so npm publish does not require a long-lived npm token.

## Non-Goals
- Publishing customer dashboard packages to npm.
- Changing ServiceRadar's server-side dashboard package import verification.

## Decisions
- Keep Forgejo-compatible CI under `.forgejo/workflows/` for the primary source repository.
- Add GitHub Actions workflows under `.github/workflows/` because the Forgejo repository is mirrored to GitHub and npm trusted publishing supports GitHub Actions OIDC.
- Use GitHub Actions `id-token: write` for the npm publish workflow and do not configure `NPM_TOKEN`.
- Require `npm test` and `npm pack --dry-run` before publishing.
- Require the package version to match the release tag (`v<package.json version>`) for tag-triggered publishes.
- Set `publishConfig.access=public` because scoped packages default to private npm access without an explicit public setting.
- Configure the npm package trusted publisher for the GitHub mirror repository and workflow filename `.github/workflows/npm-publish.yml`.

## Risks / Trade-offs
- Publishing depends on the GitHub mirror receiving the release tag and running Actions successfully.
- npm trusted publishing requires the package's trusted publisher settings on npmjs.com to exactly match the GitHub organization, repository, and workflow filename. A GitHub environment can be added later if release protection needs it.
- Publishing from tags creates a simple release model, but pre-releases need explicit semver versions in `package.json` before tagging.
- CI using npm registry packages may fail during registry outages; this is acceptable for release gating.
