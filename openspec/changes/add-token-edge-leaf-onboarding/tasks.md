## 1. Confirm before building
- [ ] 1.1 Check live deployments for existing edge sites and leaf server rows; record what removal affects.
- [ ] 1.2 Owner decision: keep the direct-leaf identity feature (written on every add-on assignment create and update by `SetDirectLeafAccess`, with `:issue_direct_access` storing a gateway-issued certificate and key) on the managed configuration, or remove it; its eligibility gate (active site, connected leaf) is unreachable today.
- [ ] 1.3 List the hub subjects an edge site uses (collectors, agents, rule bucket read) and write the leaf grant.

## 2. Core
- [ ] 2.1 Onboarding package: `nats_leaf` component type with an edge site reference; a leaf package stores no join token and no bundle.
- [ ] 2.2 Existing download and bundle routes (`POST /api/admin/edge-packages/:id/download`, `POST /api/edge-packages/:id/bundle`) refuse a `nats_leaf` package and record a security event; tests prove a leaf token is neither spent nor turned into an operator actor through them.
- [ ] 2.3 Leaf package transitions: `:bind` (`:issued` to `:bound`, stores the agent id), `:complete` (`:bound` to `:completed`, when the leaf is reported active), `:revoke` and `:expire` from `:issued` or `:bound`; a leaf package never enters `:delivered`.
- [ ] 2.4 Leaf token redemption on its own route with its own actor scoped to one site and one registered component: authorize site read, managed component registration, and issuance and status for the registered component, for one site; on first successful registration store the registered agent id on the onboarding package as the bound identity; make registration idempotent for the same site and stored agent id; refuse and record as a security event any presentation naming another agent id; take `:complete` when the leaf is reported active; record package and security events.
- [ ] 2.5 Registration accepts only an enrolled agent with a live gateway session.
- [ ] 2.6 Authorizer marks leaf servers connected and disconnected from the hub connection scan; drop `:provisioned`, `:provision` and `:reprovision` from `NatsLeafServer` so its states are `:pending`, `:connected` and `:disconnected`, with `:connect` legal from `:pending` and `:disconnected`; migrate existing `:provisioned` rows to `:pending`; site status takes `:activate` from `:pending`, `:come_online` from `:offline` and `:go_offline` from `:active`.
- [ ] 2.7 Remove the hard-coded hub address; refuse site creation and token issue without a configured address; refresh a site's address at token issue.
- [ ] 2.8 Replace the leaf's `>` grant with the list from 1.3; broker test proves an edge collector's traffic passes and an outside subject is refused.
- [ ] 2.9 Remove server-side leaf key issuance, credential minting, the provisioning worker and the bundle modules; drop unused attributes by migration.

## 3. Web UI
- [ ] 3.1 Site page: "Deploy leaf" issues a token and shows the one command, the expiry and a revoke action; remove "Download Bundle" and "Regenerate".
- [ ] 3.2 Site list and page show hub readiness and what is missing before a token can be issued.
- [ ] 3.3 Status badges from the real connection state, with "unknown" when the authorizer is not connected.
- [ ] 3.4 Replace "SaaS" wording on the edge site pages.
- [ ] 3.5 Tests for create, issue token, revoke, delete and the refused states.

## 4. CLI and API
- [ ] 4.1 `edge install leaf --token`, with no login; keep the operator-login form.
- [ ] 4.2 Remove `edge site bundle` and the bundle route; `edge site create` prints the token step.
- [ ] 4.3 Publish the CLI release.

## 5. Verify on the demo deployment
- [ ] 5.1 Create a site and issue a token in the UI; install the leaf on a lab host with only that token.
- [ ] 5.2 The site shows connected; stopping the leaf shows disconnected.
- [ ] 5.3 The token presented from another host after binding is refused and recorded; the same host resumes an interrupted install with it; a revoked token is refused.
- [ ] 5.4 The leaf is refused a hub subject outside its grant.
- [ ] 5.5 An edge collector on the site reads its rules through the leaf (task 2.1 of `refactor-collectors-onto-shared-ingest-pipeline`).

## 6. Documentation
- [ ] 6.1 Rewrite the edge leaf deployment docs around the token; remove the bundle instructions.
