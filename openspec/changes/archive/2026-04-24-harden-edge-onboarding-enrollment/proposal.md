# Change: Harden edge onboarding enrollment transport and token trust

## Why
The current edge onboarding enrollment path has multiple trust-boundary weaknesses:

- `serviceradar-cli enroll` currently defaults to skipping TLS verification for bundle downloads.
- The legacy `edgepkg-v1` onboarding token is only base64-encoded JSON and is not signed or MACed.
- The client trusts the token's embedded Core API URL and will download onboarding bundles from that origin.
- Enrollment currently allows accidental `http://` downgrade when operators omit a URL scheme.

Taken together, those behaviors make it too easy for a modified token, misconfigured CLI invocation, or on-path attacker to feed a malicious onboarding bundle to a target host. Enrollment is a privileged bootstrap path that writes config, certificates, environment overrides, and restarts services, so it needs stricter defaults and token integrity guarantees.

## What Changes
- Make edge onboarding enrollment secure by default:
  - `serviceradar-cli enroll` SHALL require certificate-validated HTTPS for remote bundle downloads.
  - The CLI SHALL NOT offer an insecure transport override.
- Add integrity protection to structured onboarding tokens by emitting signed `edgepkg-v2` tokens and treating `edgepkg-v1` as a legacy compatibility format.
- Restrict client trust in token-provided Core API endpoints so the embedded endpoint is only accepted when token integrity validation succeeds.
- Keep compatibility behavior for legacy unsigned tokens explicit by requiring a separately trusted Core API URL instead of trusting token-hosted endpoints.

## Impact
- Affected specs: `edge-onboarding`
- Affected code:
  - `go/pkg/edgeonboarding`
  - `go/pkg/cli`
  - `elixir/web-ng`
  - edge onboarding docs and operator workflows
