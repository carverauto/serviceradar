# Change: Harden Web-NG Security Controls (Round 3)

## Why
A third deep-dive security audit of `elixir/web-ng` uncovered critical vulnerabilities including RCE via shell injection, SAML authentication bypass (XSW), XML External Entity (XXE) injection, and broken sudo mode protection. These findings are distinct from the previous hardening rounds and represent high-severity risks.

## What Changes
- **Shell Injection Protection:** Implement strict escaping and validation for all user-supplied fields interpolated into bash installation/update scripts.
- **SAML Security Hardening:**
  - Mitigate XML Signature Wrapping (XSW) by ensuring the parsed assertion is the same one that was cryptographically verified.
  - Mitigate XXE by disabling DTD loading and external entity expansion in `SweetXml` and `xmerl`.
- **Sudo Mode Implementation:** Replace the no-op `require_sudo_mode` with a functional implementation and require a recent password confirmation for sensitive actions like email updates.
- **Configuration Injection Fixes:** Use proper YAML/TOML/JSON encoders or strict sanitization when generating configuration files for edge components.
- **DoS Mitigation:** Use non-raising parsing functions (e.g., `Integer.parse/1`) and `try/rescue` for atom conversion of user-supplied status filters.

## Security Findings This Proposal Addresses
- **Critical: RCE via Shell Injection in Installation Scripts**
  - `CollectorController.generate_install_script/2` and `BundleGenerator.generate_update_script/1`.
  - Un-sanitized `site` and `hostname` fields allow command injection.
- **Critical: SAML Authentication Bypass (XSW)**
  - `SAMLController.validate_saml_response/1`.
  - Signature verification and assertion parsing are decoupled, enabling injection of malicious unsigned assertions.
- **Critical: SAML XML External Entity (XXE)**
  - `SAMLController`, `SAMLStrategy`, and `AuthenticationLive`.
  - Default `SweetXml`/`xmerl` configuration allows entity expansion.
- **High: Broken Sudo Mode and Insecure Updates**
  - `UserAuth.require_sudo_mode/4`, `Accounts.sudo_mode?/1`, and `User` resource actions.
  - Sudo mode is currently a no-op, and sensitive actions like email updates don't require re-authentication.
- **Medium: YAML/TOML/K8s Configuration Injection**
  - `CollectorEnrollController.generate_config/1` and `BundleGenerator`.
  - Manual string interpolation enables configuration breakout.
- **Medium: DoS via Unhandled Exceptions**
  - `CollectorController` and `EdgeController`.
  - `String.to_existing_atom/1` and `String.to_integer/1` raise on invalid user input.

## Impact
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/collector_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/collector_enroll_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/saml_strategy.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/authentication_live.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/user_auth.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/accounts.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/edge/bundle_generator.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/edge/collector_bundle_generator.ex`
  - `elixir/serviceradar_core/lib/serviceradar/identity/user.ex`
