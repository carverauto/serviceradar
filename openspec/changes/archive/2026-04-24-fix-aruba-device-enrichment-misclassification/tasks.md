## 1. Rule Guardrails
- [x] 1.1 Audit built-in Ubiquiti rules and remove broad match conditions that can match non-Ubiquiti devices.
- [x] 1.2 Require Ubiquiti-specific evidence (for example vendor OID/model/name signals) before applying Ubiquiti vendor/type classifications.
- [x] 1.3 Add/adjust Aruba switch rules so Aruba fingerprints resolve to `vendor_name=Aruba` and `type=Switch` when evidence is present.

## 2. Regression Coverage
- [x] 2.1 Add a regression fixture for the Aruba misclassification case from issue #2915.
- [x] 2.2 Add a negative test proving Aruba fixtures do not match Ubiquiti rules.
- [x] 2.3 Preserve existing positive Ubiquiti router/switch/AP test coverage and update expected precedence where needed.

## 3. Validation
- [x] 3.1 Run targeted enrichment rule tests in `elixir/serviceradar_core`.
- [x] 3.2 Run `openspec validate fix-aruba-device-enrichment-misclassification --strict`.
