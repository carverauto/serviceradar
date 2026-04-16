## 1. Specification
- [x] 1.1 Add an OpenSpec delta that makes Forgejo on `code.carverauto.dev` the only supported repository-backed agent release source.

## 2. Implementation
- [x] 2.1 Remove GitHub release-provider support from the agent release importer and its defaults.
- [x] 2.2 Update the agent release-management and deploy LiveViews to reference Forgejo-only repository imports and links.
- [x] 2.3 Update release import and LiveView tests to cover Forgejo-only behavior.

## 3. Verification
- [x] 3.1 Validate the OpenSpec change with `openspec validate remove-github-agent-release-provider --strict`.
- [ ] 3.2 Run targeted Elixir tests for the importer and releases settings LiveView. Blocked locally because `mix test` reports `database unavailable at localhost:5432` when `SERVICERADAR_REQUIRE_DB_TESTS=1` is enabled.
