## 1. Data Model and Policy
- [x] 1.1 Add callback authentication mode and HMAC signing-secret storage to northbound action invocation targets using platform-schema Elixir migrations.
- [x] 1.2 Extend provider/action descriptor metadata parsing so integrations can advertise `token`, `hmac_optional`, or `hmac_required` callback modes.
- [x] 1.3 Ensure sensitive callback token and signing-secret material is redacted from logs, Action History, API responses, and persisted result payloads.

## 2. Callback Verification
- [x] 2.1 Preserve the raw request body for northbound callback verification in web-ng.
- [x] 2.2 Verify HMAC-SHA256 callbacks using the configured timestamp and signature headers.
- [x] 2.3 Enforce configurable timestamp skew tolerance and reject stale or future-dated signed callbacks.
- [x] 2.4 Preserve token-only callback behavior for integrations that do not opt into HMAC.
- [x] 2.5 Reject missing or invalid signatures when the target requires HMAC.

## 3. Plugin and SDK Contracts
- [x] 3.1 Extend per-target callback metadata with signature algorithm, timestamp header, signature header, and HMAC mode fields.
- [x] 3.2 Update `serviceradar-sdk-go` helpers and fixtures for signed callback metadata and webhook-only deferred results.
- [x] 3.3 Update `~/src/serviceradar-sdk-rust` with matching signed callback metadata structs/helpers.
- [x] 3.4 Update the sample northbound Wasm plugin to demonstrate token-only and HMAC-capable webhook registration paths.

## 4. Tests and Docs
- [x] 4.1 Add controller/result-handler tests for valid signed callbacks, invalid signatures, stale timestamps, missing signatures in required mode, and token-only compatibility.
- [x] 4.2 Add SDK tests for callback metadata decoding and HMAC signature helper behavior.
- [x] 4.3 Update developer/operator docs describing callback URL registration, token-only mode, HMAC mode, headers, timestamp tolerance, replay behavior, and integration compatibility guidance.
- [x] 4.4 Run focused Elixir, Go, and SDK tests for the changed callback paths.
