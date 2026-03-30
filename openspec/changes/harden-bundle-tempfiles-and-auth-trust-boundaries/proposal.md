# Change: Harden Bundle Tempfiles and Auth Trust Boundaries

## Why
Several security-sensitive paths still rely on weak trust assumptions: edge bundle tarballs are written to predictable temp paths, client IP extraction can be spoofed when `X-Forwarded-For` is enabled, token revocation state is lost on restart, and GitHub plugin import treats any GitHub-verified signer as trusted.

## What Changes
- Generate edge, collector, and edge-site tarballs using secure temporary file handling that does not rely on predictable filenames in a shared temp directory.
- Persist token revocation state durably so revoked JWTs remain revoked across `web-ng` restarts while preserving fast lookup behavior.
- Replace naive `X-Forwarded-For` parsing with trusted-proxy-aware client IP resolution.
- Require GitHub plugin imports to match an operator-configured trusted signer allowlist when GitHub signature enforcement is enabled.

## Impact
- Affected specs: `edge-onboarding`, `edge-architecture`, `ash-authentication`, `wasm-plugin-system`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng/edge/*bundle_generator.ex`, `elixir/web-ng/lib/serviceradar_web_ng/auth/token_revocation.ex`, `elixir/web-ng/lib/serviceradar_web_ng/client_ip.ex`, `elixir/web-ng/lib/serviceradar_web_ng/plugins/github_importer.ex`, auth/plugin config and tests
