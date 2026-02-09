# OpenSpec 004: Performance and Observability Improvements

## Status
Proposed

## Context
The `web-ng` Elixir Phoenix LiveView application is experiencing significant performance degradation. Initial investigation suggests this is due to inefficient RBAC (Role-Based Access Control) evaluation, potentially resulting in N+1 database queries during policy enforcement, and a general lack of observability into request lifecycles and database performance.

The system uses both `Permit` (for UI/Controller level authorization) and `Ash` (for domain-level resource policies). Both systems depend on `ServiceRadar.Identity.RBAC.permissions_for_user/2`, which frequently queries the database for `RoleProfile` records.

## Problem Statement
1.  **RBAC N+1 Queries:** `permissions_for_user` is called multiple times per request (router, LiveView mount, Ash policy checks) but often doesn't cache results, leading to repeated database hits for the same user profile.
2.  **Lack of Tracing:** The application does not currently use OpenTelemetry, making it difficult to visualize where time is being spent (e.g., in Ash actions, Ecto queries, or RBAC evaluation).
3.  **Redundant Authorization:** Both `Permit` and `Ash` perform authorization checks on the same resources, doubling the processing overhead without clear benefit.
4.  **Database Visibility:** There is no easy way to identify slow queries or correlate database performance with specific application requests.

## Proposed Changes

### 1. RBAC Evaluation Optimization
*   **Enrich Scope/Actor:** Update `ServiceRadarWebNGWeb.UserAuth.mount_current_scope/2` to load and cache user permissions in the `current_scope` struct. This ensures that subsequent calls to `WebRBAC.can?/2` or Ash policy checks (via the `actor` map) use pre-loaded permissions.
*   **Process-Level Caching:** Implement a simple process-dictionary-based cache or use `Ash.ProcessCache` in `ServiceRadar.Identity.RBAC.permissions_for_user/2` to ensure that even if a plain `%User{}` struct is passed, the `RoleProfile` is only fetched once per process.
*   **Permissions in JWT:** Consider adding a version/hash of permissions or the permissions themselves (if small enough) to the Guardian JWT claims to further reduce database lookups.

### 2. OpenTelemetry Integration
*   **Add Dependencies:** Add `opentelemetry`, `opentelemetry_exporter`, `opentelemetry_phoenix`, `opentelemetry_live_view`, `opentelemetry_ecto`, and `ash_opentelemetry` to `mix.exs`.
*   **Configuration:** Configure the OpenTelemetry exporter to send traces to the internal server at `serviceradar-otel:4317` via gRPC.
*   **Instrumentation:** Initialize instrumentation in `ServiceRadarWebNG.Application` and `ServiceRadar.Application`.

### 3. Database Performance Visibility
*   **Slow Query Logging:** Enable slow query logging in `config/prod.exs` for `ServiceRadar.Repo` with a reasonable threshold (e.g., 100ms).
*   **pg_tracing (Optional/Troubleshooting):** As suggested, consider building a custom CNPG Postgres image with `pg_tracing` to get deep visibility into query execution plans within OTEL traces.

### 4. RBAC Architecture Alignment
*   **Rationalize Policies:** Review the overlap between `Permit` actions and `Ash` resource policies. Move complex logic primarily into Ash policies where possible, and use `Permit` only for high-level UI navigation and controller-level early rejection.
*   **Unified Permission Check:** Ensure `ActorHasPermission` check in Ash consistently uses the pre-loaded permissions in the `actor` map.

## Implementation Plan
1.  **Phase 1: Quick Wins (RBAC Caching):** Implement permission caching in `UserAuth` and `RBAC` core.
2.  **Phase 2: Observability (OTEL):** Add and configure OpenTelemetry dependencies and instrumentation.
3.  **Phase 3: Database Tuning:** Enable slow query logging and analyze initial OTEL traces to identify specific slow paths.
4.  **Phase 4: Policy Cleanup:** Refactor `Permit` and `Ash` usage to reduce redundancy.

## Verification Plan
*   **Metrics:** Monitor `ash.query.stop.duration` and `serviceradar_web_ng.repo.query.query_time` via Telemetry.
*   **Traces:** Verify that traces appear in `serviceradar-otel` and clearly show the reduction in `RoleProfile` lookups.
*   **Load Testing:** Perform basic navigation through the UI and verify that page load times (TTFB) have decreased significantly.
