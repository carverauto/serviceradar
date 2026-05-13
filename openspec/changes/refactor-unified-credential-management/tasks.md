## 1. Product Shape
- [ ] 1.1 Define provider preset catalog and payload shape for AWX, Proxmox, SNMP, SSH, HTTP API, certificate, and opaque secrets.
- [ ] 1.2 Define provider-specific validation and redaction labels for each preset.
- [ ] 1.3 Decide final route naming and navigation placement for the unified Credentials area.

## 2. Data/API
- [ ] 2.1 Add or normalize metadata needed to classify existing secrets by provider, auth method, and usage.
- [ ] 2.2 Add provider/auth validation helpers shared by LiveView forms and Ash changes.
- [ ] 2.3 Preserve existing Proxmox rule compilation and broker-grant behavior.
- [ ] 2.4 Add usage lookup so a secret can show its linked rules/controllers/profiles/plugins without exposing payloads.

## 3. UI
- [ ] 3.1 Replace free-text provider with preset selection and advanced custom-provider escape hatch.
- [ ] 3.2 Replace generic auth-method dropdown with provider-aware auth choices.
- [ ] 3.3 Allow inline secret creation/rotation while creating or editing a rule.
- [ ] 3.4 Add a provider-neutral secrets list with filters, use count, rotation metadata, and redacted status.
- [ ] 3.5 Update AWX controller and repository forms to accept token/deploy token input directly while also supporting existing secret selection.
- [ ] 3.6 Update copy and links so credential rules are described as platform-wide scoped credential bindings, not Proxmox-only setup.

## 4. Consumers
- [ ] 4.1 Integrate AWX controller token storage with the unified secret list.
- [ ] 4.2 Map Proxmox API and console rules to the new provider preset model.
- [ ] 4.3 Plan SNMP profile/discovery migration points without breaking current SNMP credential behavior.
- [ ] 4.4 Plan plugin secret-reference reuse so plugin packages can point users to the same credentials area.

## 5. Docs and Tests
- [ ] 5.1 Add a general credentials guide and provider-specific subsections.
- [ ] 5.2 Replace broken or overly narrow Proxmox-only links from credential UI.
- [ ] 5.3 Add LiveView tests for provider preset switching, inline secret creation, existing secret selection, and redaction.
- [ ] 5.4 Add regression tests for existing Proxmox rules and brokered plugin assignment output.
