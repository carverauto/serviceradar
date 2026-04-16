# Change: Remove GitHub agent release provider

## Why
The agent release-management workflow still exposes GitHub as a supported release provider and defaults operators to `https://github.com/carverauto/serviceradar`. ServiceRadar has moved its release source of truth to Forgejo at `https://code.carverauto.dev/carverauto/serviceradar`, so the current UI and importer behavior now point operators at the wrong system.

## What Changes
- Remove GitHub as a supported repository release provider for agent release import.
- Default repository release import to Forgejo at `https://code.carverauto.dev/carverauto/serviceradar`.
- Update operator-facing release-management and deploy copy so release links reference Forgejo instead of GitHub.
- Keep manual release publishing available for local and developer workflows.
- Update automated tests to cover Forgejo-only release import behavior.

## Impact
- Affected specs: `edge-architecture`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng/edge/release_source_importer.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/agents_live/releases.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/agents_live/deploy.ex`
  - `elixir/web-ng/test/app_domain/edge/release_source_importer_test.exs`
  - `elixir/web-ng/test/phoenix/live/settings/agents_releases_live_test.exs`
