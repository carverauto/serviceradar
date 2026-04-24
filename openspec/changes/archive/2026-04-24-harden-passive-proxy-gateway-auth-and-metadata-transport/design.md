## Context
`GatewayAuth` is the passive proxy entrypoint for edge proxies that inject an identity JWT. Today it can accept and provision users from a token even when no signature verification material is configured. Separately, the auth outbound URL policy still has an escape hatch that permits `http://` metadata and JWKS URLs.

## Goals
- Fail closed for passive proxy auth when signature verification is not configured.
- Keep all auth metadata, JWKS, and related discovery traffic on HTTPS only.
- Preserve the existing signed-token and verified-JWKS/public-key flows.

## Non-Goals
- Changing passive proxy claim mapping behavior beyond the verification gate.
- Adding new gateway auth modes or alternate trust models.

## Decisions

### Passive Proxy Must Require Verification Material
When passive proxy mode is enabled, `GatewayAuth` SHALL reject gateway tokens unless either:
- a JWKS URL is configured, or
- a static public key PEM is configured.

The plug should treat missing verification config as a hard configuration error for authentication, not a trusted upstream shortcut.

### Metadata Transport Must Stay HTTPS
The shared outbound auth URL policy SHALL reject insecure `http://` URLs unconditionally. The `:allow_insecure_metadata_urls` downgrade path should be removed so auth discovery and JWKS retrieval cannot silently weaken transport security.

## Verification
- Add a passive proxy regression that proves unsigned tokens are rejected when verification config is absent.
- Add an outbound URL policy regression that proves `http://` auth metadata URLs are rejected regardless of config.
