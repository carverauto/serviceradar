## Context

`migrate-controllers-to-security-pipelines` (merged) moved every
HTML auth surface and OAuth `/token` off the
`ServiceRadarWebNGWeb.Auth.RateLimiter` shim. Three callers
explicitly stayed inline because the plug's default 429 JSON
shape diverged from the client contracts:

- `cli_auth_controller` emits `{code, error, message}` via
  `rate_limited_response/2`. `serviceradar-cli` device-flow
  clients parse those fields.
- `dashboard_package_publish_controller` emits a similar envelope.
- `live/auth_live/local_sign_in.ex` uses the shim for a
  pre-render rate-limit *display* (the credential POST itself
  already went through the migrated pipeline).

The deferred work is twofold: extend the plug so per-pipeline
JSON shapes are possible, and then migrate the three call sites
behind that extension.

## Goals / Non-Goals

**Goals**

- Per-pipeline JSON 429 / 423 bodies so existing CLI / dashboard
  clients keep parsing the same shape.
- Move the last three callers of the `Auth.RateLimiter` shim
  onto either the plug (for CLI and dashboard publish) or the
  direct `ServiceRadar.Security.RateLimiter` API (for the
  LiveView display).
- Delete the shim. Tests that exercised it move to exercising
  the central limiter and the plug.

**Non-Goals**

- Changing the client-facing JSON shape. Body parity is a hard
  constraint.
- Restructuring `cli_auth_controller` beyond stripping the
  rate-limit machinery.
- Touching the LiveView's actual auth POST path (that already
  migrated).
- Adding HTML mode to the CLI or dashboard publish routes. They
  are JSON-only.

## Decisions

### D1. `:json_body_builder` opt instead of a registry of named shapes

The plug exposes a 1-arity function opt rather than a fixed list
of named shapes (`:standard | :cli | :dashboard_publish`). The
function takes `retry_after` and returns iodata. This keeps the
plug decoupled from the controllers it serves and lets
deployments add a shape without code changes in the plug. The
default body stays the same.

Lockout has no `retry_after` (the lockout could be hours), so
its builder is 0-arity.

### D2. Edit the existing `:rate_limit_dashboard_publish` pipeline in place

The proposal mentions a `_v2` suffix as an alternative; the
in-place edit is cleaner. The dashboard publish pipeline already
isn't used by any route, so there's no existing consumer to
break. Update the pipeline definition with the dashboard
controller's `json_body_builder`, then wire the publish routes
through it.

### D3. New `:rate_limit_cli_device` pipeline, distinct from `:rate_limit_cli_device_auth`

The pre-existing `:rate_limit_cli_device_auth` pipeline (added in
the platform-security-hardening change) used the default JSON
body. The CLI controller has multiple endpoints with the *same*
legacy body; the cleanest path is to update that existing
pipeline in-place with the new body builder, then wire it onto
the routes. The proposal text uses `:rate_limit_cli_device` as a
working name — landing as a rename of the existing pipeline is
fine. (No external consumer references it by name.)

### D4. The LiveView display is one line; not worth a pipeline

`local_sign_in.ex` calls `RateLimiter.check_rate_limit/3` to
*ask* whether the IP is currently rate-limited, so the form can
disable submit and show a banner. It does not record an attempt
— the actual record happens when the user POSTs the form, and
the POST goes through the `:rate_limit_auth_local` pipeline that
already migrated. Switching that one call from the shim to
`ServiceRadar.Security.RateLimiter.check/3` removes the
LiveView's dependency on the shim with zero behavior change.

### D5. Tests for body parity

Every route this change migrates already has an integration test
that asserts the 429 response shape. The migration tasks must
keep those tests green (no edits to the assertions) so the
client contract is enforced as a regression test, not just as
documentation. The plug tests separately exercise the
`json_body_builder` interaction.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Bucket key rename invalidates in-flight rate-limit state | Document in release notes; legitimate users won't notice. Hostile clients at the limit aren't owed a smooth transition. |
| Builder function raises at request time | Wrap the builder call in try/rescue; on error, fall back to the default body and log a warning. |
| `local_sign_in.ex` LiveView returns stale rate-limit state | Pre-existing race (the displayed state lags the real bucket); not introduced by this change. Document the limitation. |
| Some test that exercises the shim was missed in the search | The shim's `def`s become routes-of-record: a final compile after deletion fails fast if any caller remains. |

## Migration Plan

1. Land plug body-builder opt + plug tests.
2. Update `:rate_limit_cli_device_auth` and
   `:rate_limit_dashboard_publish` pipelines with their body
   builders. (Rename if Section 2.2 lands on a successor name.)
3. Migrate the CLI auth controller. Run its tests; assert body
   parity.
4. Migrate the dashboard publish controller. Run its tests;
   assert body parity.
5. Swap the LiveView's display call from shim to direct API.
6. `grep -r "Auth\.RateLimiter"` — should be empty. Delete the
   shim and its test file.

Each step is independently revertible.

## Open Questions

1. Should the body builder also receive the `conn` so it can
   include the actor id in the response body when known? v1
   doesn't, but the option is forward-compatible if added.
2. Are there any other JSON shapes elsewhere in the repo that
   parsed CLI clients depend on and might want the same plug
   facility? The CTI signal endpoints and a few SRQL gateway
   surfaces look similar; out of scope here but flagged.
