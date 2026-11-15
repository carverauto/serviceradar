# Proposal: remove stored inline SNMP credentials

## Problem

Once an SNMP profile, legacy SNMP target or per-device SNMP override stores an
inline community string, auth password or privacy password, nothing can remove
it:

- The update actions take `community`, `auth_password` and `priv_password` as
  `:string` arguments. Ash's `:string` type trims input and casts `""` to `nil`
  before any change sees it, so `EncryptCredentials` cannot tell "clear" from
  "unchanged". Its `"" -> nil` branch was unreachable.
- The settings form drops blank password fields on edit ("Leave blank to keep
  existing") and offers no removal control.
- Binding a reusable credential (`credential_secret_id`) leaves the inline
  material behind. `CredentialResolver` never reads it while a credential is
  bound, so it is an unused secret at rest, and unbinding the credential later
  silently puts the stale value back into service.

## What this changes

1. Every action that declares `CredentialDsl.credential_action_arguments/0`
   gains `clear_credentials`, a list drawn from `community`, `auth_password`
   and `priv_password`. A listed field is removed. Supplying a value for a field
   and listing it in the same call is rejected. A blank value still means
   "keep", by design.
2. A call that binds a reusable credential (changes `credential_secret_id` to a
   different non-nil value) removes all inline credential material; re-sending
   the id already bound removes nothing. A call that supplies a non-nil
   `credential_secret_id`, changed or re-sent, cannot also supply inline
   values. Changing only the SNMP version does not
   remove anything: switching v2c to v3 and back is a reversible configuration
   change, and the form now shows the stored material it would leave unused.
3. The SNMP profile edit form lists the inline credentials the profile still
   stores, says when one is unused by the current version or credential
   selection, and lets the operator tick each one for removal on save.

`DeviceSNMPCredential` now declares the shared argument macro instead of its own
copy, so it gets `clear_credentials` too. Its device form and the legacy target
modal (read-only for existing targets) are not changed.

## Impact

- Affected spec: `snmp-checker` (one ADDED requirement).
- Affected code: `SNMPProfiles.CredentialDsl`,
  `SNMPProfiles.Changes.EncryptCredentials`, `Inventory.DeviceSNMPCredential`,
  web-ng `SNMPProfilesLive` profile form.
- No migration. Existing rows keep their material until an operator removes it
  or binds a different reusable credential.
