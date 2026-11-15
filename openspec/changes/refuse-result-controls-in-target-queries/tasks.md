## 1. Implementation
- [x] 1.1 Add `ServiceRadar.SRQLTargetQuery.validate/2` with the refused-token rule.
- [x] 1.2 Add `ServiceRadar.Validations.TargetQuery` and switch every target-query resource to it; delete the per-resource validators.
- [x] 1.3 Validate plugin target policy inputs, producer schedule target queries and MTR policy selectors on save.
- [x] 1.4 Drop the NetBox `limit:1` default target query; document the rule.

## 2. Verification
- [x] 2.1 Validator: each refused token is named; sort, time and filters pass; entity restriction.
- [x] 2.2 Credential rule: create and update refuse `limit:`; an update that leaves a stored `limit:` query alone is accepted.
- [x] 2.3 Count stored target queries carrying a refused token on demo (read-only).
