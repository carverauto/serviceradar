## 1. Canonical Endpoint Attachment Read Model
- [ ] 1.1 Verify canonical AGE projection emits endpoint attachment relations for discovered client devices with stable source/target device IDs and endpoint-specific relation metadata.
- [x] 1.2 Ensure the God-View runtime graph and snapshot pipeline preserve endpoint attachment rows instead of collapsing or discarding them during normalization.
- [x] 1.3 Add backend tests that cover a mixed topology fixture with router/switch backbone edges and downstream client endpoint attachments.

## 2. God-View Layer and Rendering Semantics
- [x] 2.1 Ensure enabling the `endpoints` layer renders endpoint nodes and attachment links on the topology canvas.
- [x] 2.2 Ensure disabling the `endpoints` layer hides only endpoint attachments and does not hide backbone infrastructure nodes or links.
- [x] 2.3 Add frontend and LiveView regression tests for the endpoint layer toggle using payloads that include both backbone and endpoint attachment relations.

## 3. Verification
- [ ] 3.1 Validate the issue scenario end-to-end with a representative fixture or replay so discovered endpoints are visible when `endpoints` is enabled.
- [x] 3.2 Run `openspec validate add-topology-endpoint-visibility --strict`.
