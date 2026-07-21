## 1. Product Shape
- [x] 1.1 Define one bounded credential descriptor and encrypted payload contract for approved integration packages.
- [x] 1.2 Define descriptor-driven field validation, public metadata, and redaction behavior without provider-specific core allowlists.
- [ ] 1.3 Decide final route naming and navigation placement for the unified Credentials area.
- [ ] 1.4 Inventory every credential entry point and assign an owning package or native descriptor.

## 2. Data/API
- [ ] 2.1 Add or normalize metadata needed to classify existing secrets by provider, auth method, and usage.
- [ ] 2.2 Add generic descriptor/auth/field/runtime-template validation shared by manifest import, LiveView forms, materialization, and Ash changes.
- [x] 2.3 Preserve existing Proxmox rule compilation and broker-grant behavior.
- [ ] 2.4 Add usage lookup so a secret can show its linked rules/controllers/profiles/plugins without exposing payloads.
- [x] 2.5 Build one duplicate-safe runtime catalog exclusively from approved package descriptors for Wasm-backed integrations.

## 3. UI
- [x] 3.1 Replace hard-coded New Rule/New Secret provider menus with descriptor catalog entries.
- [x] 3.2 Render auth methods and secret fields from the selected descriptor using bounded generic controls.
- [x] 3.3 Allow inline secret creation/rotation while creating or editing a rule.
- [ ] 3.4 Add a provider-neutral secrets list with filters, use count, rotation metadata, and redacted status.
- [ ] 3.5 Update AWX controller and repository forms to accept token/deploy token input directly while also supporting existing secret selection.
- [x] 3.6 Update copy and links so credential rules are described as platform-wide scoped credential bindings, not Proxmox-only setup.
- [ ] 3.7 Remove provider names and provider-specific documentation links from core/web-ng source and tests.

## 4. Consumers
- [ ] 4.1 Integrate AWX controller token storage with the unified secret list.
- [x] 4.2 Move Proxmox, UniFi Protect, Axis, AWX, and OpenText credential declarations into their package manifests and remove native-profile fallbacks.
- [ ] 4.3 Migrate SNMP polling/traps and mapper/discovery to native descriptors and reusable broker references without breaking current profiles.
- [ ] 4.4 Migrate plugin secret-reference fields to the same descriptor catalog and credentials area.
- [ ] 4.5 Migrate remote access and remaining consumer-local credential stores to broker references.
- [ ] 4.6 Keep all plaintext material inside trusted protocol adapters; prove Wasm guests receive neither source credentials nor derived tokens.
- [ ] 4.7 Define package-owned credential test actions and replace the Proxmox-specific rule test plan and dispatcher in core.

## 5. Docs and Tests
- [ ] 5.1 Add a general credentials guide and provider-specific subsections.
- [ ] 5.2 Replace broken or overly narrow Proxmox-only links from credential UI.
- [x] 5.3 Add LiveView tests for descriptor switching, inline secret creation, existing secret selection, catalog-only menus, and redaction.
- [ ] 5.4 Add regression tests for existing Proxmox rules and brokered plugin assignment output.
- [x] 5.5 Add contract tests proving a new fixture provider appears without any core/web-ng provider registration.
