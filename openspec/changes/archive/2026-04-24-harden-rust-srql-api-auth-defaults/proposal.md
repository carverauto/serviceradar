# Change: Harden Rust SRQL API Auth Defaults

## Why
The repository security review found that `rust/srql` disables API key enforcement entirely when neither `SRQL_API_KEY` nor a KV-backed API key is configured. That leaves the query and translate endpoints unauthenticated through simple configuration omission.

## What Changes
- Require an API key source for standalone SRQL server startup.
- Fail closed when neither `SRQL_API_KEY` nor `SRQL_API_KEY_KV_KEY` resolves to a usable key.
- Preserve explicit embedded/test construction where unauthenticated use is intentional and local.
- Add focused Rust tests for the stricter SRQL auth-default contract.

## Impact
- Affected specs: `srql`
- Affected code: `rust/srql`
