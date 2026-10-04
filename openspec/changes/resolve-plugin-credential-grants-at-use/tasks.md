## 1. Contract
- [x] 1.1 Add `assignment_id` and `binding_id` to `CredentialBrokerResolveRequest`; regenerate Go and Elixir protobufs
- [x] 1.2 Agent advertises `credential_broker_resolve_by_binding` in `AgentHelloRequest.capabilities`; core records it

## 2. Core
- [x] 2.1 `CredentialBrokerGrant.reuse_or_issue/2` (scope-keyed reuse, existing `:issue` action and guards)
- [x] 2.2 Resolve-by-binding in `AgentGatewaySync.resolve_credential_broker_grant/1`: authorize against the current assignment and binding, re-derive scope, reuse or mint, resolve, audit denials
- [x] 2.3 Materializer writes grant scope, never mints; reconciler comparison unchanged
- [x] 2.4 Config generation: binding-only delivery for capable agents; legacy embedded grant with scope-keyed reuse otherwise
- [x] 2.5 Gateway forwards the new request fields

## 3. Agent
- [x] 3.1 Host HTTP resolve sends assignment and binding ids when the binding has no grant id; falls back to the embedded grant when present
- [x] 3.2 Host-authority checks (consumer, purpose, rule, origin, console path rules) run on the binding scope

## 4. Verification
- [x] 4.1 Integration: resolve by binding mints once and reuses; disabled rule, changed secret, wrong agent, foreign assignment, unknown binding all deny and audit
- [x] 4.2 Integration: legacy agent config still carries a grant and resolves; repeated config generation reuses it
- [x] 4.3 Agent test: binding-only config resolves; legacy embedded grant still resolves
- [ ] 4.4 Measure: grants minted per agent per day before and after on a lab deployment (after the core and agent release reaches a lab deployment)
