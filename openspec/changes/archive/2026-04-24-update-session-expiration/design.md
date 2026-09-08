## Context
Users report frequent logouts in web-ng. Session behavior likely spans core-elx AshAuthentication token configuration and web-ng cookie/session handling. Current idle and absolute expiration behavior is unclear.

## Goals / Non-Goals
- Goals: consistent idle + absolute expiration behavior, refresh on any authenticated request, configurable TTLs with a 1 hour idle default, and clear diagnostics for expiration.
- Non-Goals: new authentication providers, multi-tenant changes, user-facing idle timeout warnings, or redesigning auth UI flows.

## Decisions
- Add a configurable idle timeout with a default of 1 hour and an absolute session lifetime cap.
- Refresh session expiration on any authenticated request within the idle window.
- Align client session storage (cookie max-age) with server token TTLs.
- Emit structured logs or telemetry when sessions expire to aid debugging.

## Risks / Trade-offs
- Longer sessions increase exposure if a session is compromised. Mitigate with an absolute lifetime cap and logout controls.
- Refresh-on-activity can mask inactivity-based logout expectations if idle timeout is too long.

## Migration Plan
- Introduce configuration with safe defaults.
- Roll out config updates and verify session behavior in web-ng.
- No data migrations expected.

## Open Questions
- None
