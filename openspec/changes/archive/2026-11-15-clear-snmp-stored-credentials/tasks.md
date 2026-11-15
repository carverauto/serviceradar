## 1. Resource contract
- [x] 1.1 `clear_credentials` argument in `CredentialDsl.credential_action_arguments/0`
- [x] 1.2 `EncryptCredentials`: set / keep / clear per field; binding a reusable credential clears inline material; conflicting inputs rejected
- [x] 1.3 `DeviceSNMPCredential` uses the shared argument macro

## 2. Settings UI
- [x] 2.1 Profile edit form lists stored inline credentials with a removal checkbox and an unused-by-current-selection note
- [x] 2.2 Credential input errors render on the form

## 3. Tests
- [x] 3.1 `snmp_profile_test.exs`: blank keeps, clear removes, binding removes, conflicts rejected (fail-first)
- [x] 3.2 `snmp_profiles_live_test.exs`: ticking removal on the edit form clears the stored community (fail-first)

## 4. Validation
- [x] 4.1 `openspec validate clear-snmp-stored-credentials --strict`
- [x] 4.2 Format, Credo, no-mistakes gate, CI green
