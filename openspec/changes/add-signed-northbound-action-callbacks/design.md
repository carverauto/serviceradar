## Context
Northbound action callbacks are currently protected by a per-target random token supplied in `x-serviceradar-callback-token`, bearer auth, or request body. The token is hashed at rest and compared with `Plug.Crypto.secure_compare/2`, which is appropriate for compatibility but does not authenticate the exact request body. Some external systems support signed webhooks; others only support static headers.

## Goals / Non-Goals
- Goals:
  - Preserve token-only callbacks for integrations that cannot sign webhook bodies.
  - Support an HMAC-SHA256 mode that signs the raw request body plus timestamp metadata.
  - Allow individual action providers or descriptors to require HMAC where supported.
  - Document the callback contract for integration developers.
- Non-Goals:
  - Do not make HMAC mandatory for every callback integration.
  - Do not require vendor-specific signing schemes in the first version.
  - Do not replace the existing per-target bearer token gate.

## Decisions
- Keep the existing callback token as the baseline authorization mechanism.
- Add an HMAC mode that can be `optional` or `required` per target, derived from provider/action configuration or a deferred action response hint.
- Generate a separate per-target signing secret for HMAC-capable targets and store it as sensitive encrypted state. A one-way hash is not enough because the verifier needs the secret to recompute the request MAC.
- Sign the canonical message as `<timestamp>.<raw_body>` using HMAC-SHA256 and expose headers:
  - `x-serviceradar-callback-token`
  - `x-serviceradar-callback-timestamp`
  - `x-serviceradar-callback-signature`
- Accept a signature value with a clear scheme prefix, for example `sha256=<hex-digest>`.
- Enforce a configurable timestamp tolerance, defaulting to five minutes, before applying callback payload state changes.
- Use constant-time comparison for both token-hash and signature comparisons.

## Risks / Trade-offs
- Token-only callbacks remain susceptible to replay within the lifetime of a leaked token; mitigation is to let sensitive providers require HMAC.
- HMAC requires storing a recoverable signing secret; mitigation is to store it as sensitive encrypted state and avoid logging it.
- Raw-body verification requires the controller to preserve the exact request body bytes; mitigation is to add focused controller tests.
- Some vendors use custom signature formats; mitigation is to start with ServiceRadar-native HMAC metadata and leave vendor-specific schemes for provider plugins.

## Migration Plan
- Existing token-only callbacks continue working unchanged.
- New targets receive additional HMAC metadata only when enabled by configuration or action response hints.
- Existing targets without HMAC state continue validating with the current token-only path.

## Open Questions
- Should the HMAC mode be declared only in provider/descriptor metadata, only in plugin deferred responses, or both with descriptor policy as the upper bound?
- Should webhook callbacks become single-use by default after terminal completion, or remain idempotent for repeated vendor delivery attempts?
