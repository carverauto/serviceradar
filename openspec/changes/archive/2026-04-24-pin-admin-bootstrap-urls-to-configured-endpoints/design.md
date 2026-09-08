## Context
The public delivery endpoints no longer trust request host data, but the admin UI still uses LiveView connection URI data to build copied install commands and onboarding tokens. Those generated artifacts are security-sensitive because operators paste them into shells and the CLI may trust a token-embedded API URL.

## Goals
- Ensure bootstrap commands and signed onboarding tokens use only configured endpoint URLs.
- Remove host-header influence from admin-generated bootstrap artifacts.

## Non-Goals
- Redesign the onboarding token format.
- Remove the optional `api` field from signed onboarding tokens.

## Decisions
### Canonical URL source
- Admin LiveViews SHALL use the configured Phoenix endpoint URL, not `get_connect_info(socket, :uri)`, when generating bootstrap commands and onboarding tokens.

### Agent enroll command
- The copied agent enroll command SHALL always include an explicit `--core-url` argument matching the canonical configured endpoint URL.
- The signed onboarding token MAY still include `api`, but operator-visible commands SHALL not depend on it.
