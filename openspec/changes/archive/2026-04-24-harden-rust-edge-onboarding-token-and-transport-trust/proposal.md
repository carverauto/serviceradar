# Change: Harden Rust Edge Onboarding Token And Transport Trust

## Why
The repository security review found that `rust/edge-onboarding` still accepts legacy and `edgepkg-v1` onboarding token formats, lets `--host` or `CORE_API_URL` replace the token's API URL, and defaults bare bootstrap hosts to plaintext HTTP. That no longer matches the signed-only, HTTPS-only onboarding contract already enforced in the Go and Elixir onboarding paths.

## What Changes
- Remove legacy/raw token parsing from the Rust onboarding crate.
- Require the current signed onboarding token format only.
- Stop allowing host override input to replace the token's API URL.
- Require explicit secure Core API URLs for package download and reject plaintext or scheme-less bootstrap endpoints.
- Add focused Rust tests for the stricter token and transport contract.

## Impact
- Affected specs: `edge-onboarding`
- Affected code: `rust/edge-onboarding`
