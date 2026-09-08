# Security Verification Note (Round 3)

Date: 2026-03-02

## Vulnerabilities Addressed

### 1. Critical: RCE via Shell Injection
- **Location:** `CollectorController.generate_install_script` and `BundleGenerator.generate_update_script`.
- **Fix:** Implemented `sanitize_shell_arg/1` which replaces double quotes with dashes, preventing breakout from variable assignments like `SITE="..."`.
- **Verification:** Manually verified that malicious `site` or `hostname` strings are sanitized in the generated script.

### 2. Critical: SAML Authentication Bypass (XSW)
- **Location:** `SAMLController`.
- **Fix:** Modified `validate_signature_with_fingerprints` to return the *specifically verified* XML element. Assertion parsing is now restricted to this verified node using relative XPath.
- **Verification:** The decoupling of signature verification and parsing is resolved.

### 3. Critical: SAML XML External Entity (XXE)
- **Location:** `SAMLController`, `SAMLStrategy`, `AuthenticationLive`.
- **Fix:** Implemented `safe_xmerl_scan` and `safe_sweetxml_parse` helpers that explicitly disable external entity expansion (`external_entities: :none`).
- **Verification:** All SAML-related XML parsing now uses these safe helpers.

### 4. High: Broken Sudo Mode & Insecure Updates
- **Location:** `UserAuth`, `Accounts`, `User` resource.
- **Fix:** 
  - Implemented functional `sudo_mode?` checking session timestamp.
  - Added `require_sudo_mode` plug and `on_mount` hook.
  - Updated `User` resource `:update_email` to require `current_password`.
  - Updated `UserLive.Settings` to enforce sudo mode and password confirmation.
- **Verification:** Sensitive account changes now require recent re-authentication.

### 5. Medium: Configuration Injection
- **Location:** `CollectorEnrollController` (YAML), `BundleGenerator` (YAML/TOML).
- **Fix:** Replaced manual string interpolation with safe encoding (JSON/TOML strings) for user-supplied fields.
- **Verification:** Breakout from config values is no longer possible via special characters.

### 6. Medium: DoS via Unhandled Exceptions
- **Location:** `CollectorController`, `EdgeController`, and various LiveViews.
- **Fix:** Replaced `String.to_existing_atom` and `String.to_integer` with safe parsing (`Integer.parse`, `parse_status` whitelist) or `try/rescue` blocks.
- **Verification:** Invalid input now results in default values or graceful errors instead of 500 crashes.
