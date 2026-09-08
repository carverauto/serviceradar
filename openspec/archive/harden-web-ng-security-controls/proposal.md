# Change: Harden Web-NG Security Controls

## Why
A targeted security deep dive of `elixir/web-ng` found multiple exploitable or high-risk gaps in XSS handling, SAML assertion validation, and outbound URL handling for identity-provider configuration.

Most notably, plugin-driven markdown is rendered with `raw/1` and can emit dangerous links (for example, `javascript:` URLs), and SAML callback validation currently permits non-cryptographic signature checks.

## What Changes
- Add strict sanitization for plugin markdown rendering before HTML is inserted into templates.
- Strengthen browser Content Security Policy defaults to reduce XSS blast radius.
- Replace permissive SAML validation with fail-closed cryptographic verification and stricter assertion checks.
- Add outbound URL validation/guardrails for OIDC discovery, SAML metadata, and gateway JWKS fetches to reduce SSRF exposure.
- Add regression tests for XSS payloads, SAML validation behavior, and outbound URL policy enforcement.

## Security Findings This Proposal Addresses
- **Stored/Reflected XSS risk in markdown widget rendering**
  - [`elixir/web-ng/lib/serviceradar_web_ng_web/components/plugin_results.ex:144`](/home/mfreeman/serviceradar/elixir/web-ng/lib/serviceradar_web_ng_web/components/plugin_results.ex:144)
  - `raw(@html)` renders Earmark output directly; markdown links can still generate dangerous protocols.
- **SAML signature verification bypass risk**
  - [`elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex:311`](/home/mfreeman/serviceradar/elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex:311)
  - [`elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex:580`](/home/mfreeman/serviceradar/elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex:580)
  - Validation falls back to `:ok` when no certs are found and only checks signature structure rather than cryptographic validity.
- **Potential SSRF from admin-configured URL fetches**
  - [`elixir/web-ng/lib/serviceradar_web_ng_web/auth/oidc_client.ex:162`](/home/mfreeman/serviceradar/elixir/web-ng/lib/serviceradar_web_ng_web/auth/oidc_client.ex:162)
  - [`elixir/web-ng/lib/serviceradar_web_ng_web/auth/saml_strategy.ex:142`](/home/mfreeman/serviceradar/elixir/web-ng/lib/serviceradar_web_ng_web/auth/saml_strategy.ex:142)
  - [`elixir/web-ng/lib/serviceradar_web_ng_web/plugs/gateway_auth.ex:218`](/home/mfreeman/serviceradar/elixir/web-ng/lib/serviceradar_web_ng_web/plugs/gateway_auth.ex:218)
  - [`elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/authentication_live.ex:955`](/home/mfreeman/serviceradar/elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/authentication_live.ex:955)
  - URLs are fetched without explicit scheme/host/IP policy controls.
- **CSP allows inline scripts/styles, reducing XSS containment**
  - [`elixir/web-ng/lib/serviceradar_web_ng_web/router.ex:12`](/home/mfreeman/serviceradar/elixir/web-ng/lib/serviceradar_web_ng_web/router.ex:12)

## Impact
- Affected specs: `web-ng-security-controls` (new)
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/plugin_results.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/oidc_client.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/saml_strategy.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/plugs/gateway_auth.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/authentication_live.ex`
  - Associated tests under `elixir/web-ng/test/`
