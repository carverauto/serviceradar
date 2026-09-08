# Change: Add signed northbound action callbacks

## Why
Northbound action callbacks currently authenticate with a per-target bearer token. That keeps compatibility with simple external systems, but it does not prove callback body integrity or provide timestamp-based replay protection for systems that can sign webhook requests.

## What Changes
- Add optional HMAC-SHA256 verification for northbound action callback requests while keeping token-only callbacks as the default compatibility mode.
- Extend per-target callback metadata so plugins can register external systems with the callback URL, token header, signature headers, timestamp header, and signing algorithm.
- Allow an action/provider to require HMAC verification for callbacks when the external integration supports it; token-only callbacks remain supported for systems that cannot sign payloads.
- Verify signatures against the raw request body, enforce a bounded timestamp tolerance, and reject missing/invalid signatures when HMAC is required.
- Add tests and documentation for token-only, signed, replay-window, and invalid-signature callback flows.

## Impact
- Affected specs: `wasm-plugin-system`, `plugin-sdk-go`, `platform-security`
- Affected code: northbound action dispatcher/result handler, web-ng callback controller, callback target persistence, Go/Rust SDK callback helpers, sample northbound plugin, docs
