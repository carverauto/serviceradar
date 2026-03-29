## Context
SRQL exposes `/api/query` and `/translate` over its standalone HTTP server. The server currently enforces API key authentication only if a key is configured. If neither `SRQL_API_KEY` nor a KV-backed key is present, startup succeeds and the service simply logs that authentication is disabled.

That is a fail-open auth boundary for a query service that should not serve unauthenticated requests by default.

## Goals
- Make standalone SRQL startup fail closed when API authentication is not configured.
- Preserve intentional embedded/test use cases without forcing external API auth into those local harnesses.
- Keep KV-backed API key rotation support intact.

## Non-Goals
- Redesigning SRQL query parsing or execution.
- Adding a second authentication mechanism.
- Changing embedded in-process SRQL semantics for tests.

## Decisions
### Require a usable API key source for server startup
The standalone server should not bind its HTTP listener unless there is a current API key from either environment or KV. Missing key configuration becomes a startup error rather than a runtime warning.

### Keep embedded/test behavior explicit
`EmbeddedSrql` and test harness construction already bypass the external server startup path intentionally. The hardening should focus on `Server::new` / startup behavior rather than forcing auth into every embedded use.

## Verification
- Unit or integration tests cover missing-key startup failure.
- Existing authenticated server behavior continues to work with env-based and KV-based keys.
- OpenSpec validation passes for the new change and updated baseline artifact.
