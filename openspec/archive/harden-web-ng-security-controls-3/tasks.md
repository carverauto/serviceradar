## 1. DoS Mitigation
- [x] 1.1 Replace `String.to_existing_atom/1` with safe parsing in `CollectorController.index` and `credentials`.
- [x] 1.2 Replace `String.to_integer/1` with `Integer.parse/1` in `EdgeController.events`.
- [x] 1.3 Audit and fix `String.to_integer/1` in major LiveViews (`ServiceLive`, `JobLive`, `SnmpProfilesLive`).

## 2. Shell and Configuration Injection Protection
- [x] 2.1 Sanitize/escape `site` and `hostname` in `CollectorController.generate_install_script`.
- [x] 2.2 Sanitize/escape fields in `BundleGenerator` (shell scripts, K8s manifests).
- [x] 2.3 Use proper YAML encoding in `CollectorEnrollController.generate_config`.
- [x] 2.4 Use proper TOML encoding in `CollectorBundleGenerator.generate_flowgger_config`.

## 3. SAML Security Hardening
- [x] 3.1 Disable XXE in `SweetXml` and `xmerl` across SAML components.
- [x] 3.2 Fix XSW by validating that the parsed assertion is the signed one in `SAMLController`.

## 4. Sudo Mode and User Updates
- [x] 4.1 Implement functional `Accounts.sudo_mode?` and `UserAuth.require_sudo_mode`.
- [x] 4.2 Update `User` resource `:update_email` action to require current password or recent sudo authentication.
- [x] 4.3 Update `UserLive.Settings` to handle password/sudo re-authentication for email changes.
