# Change: Update session expiration policy

## Why
Users report needing to log in more frequently than expected (issue #2603). We need consistent, configurable session lifetimes between server tokens and client cookies and clearer expiration behavior to avoid surprise logouts.

## What Changes
- Define session expiration as a combination of idle timeout (default 1 hour) and absolute lifetime, both configurable.
- Refresh sessions on any authenticated request to prevent premature logouts within the idle window.
- Ensure client session storage aligns with server token TTLs.
- Add diagnostics to surface the expiration reason for debugging.

## Impact
- Affected specs: ash-authentication
- Affected code: elixir/serviceradar_core authentication config, web-ng session handling, edge proxy auth middleware (if applicable)
