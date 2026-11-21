## 1. Confirm before building
- [ ] 1.1 Check live deployments for existing edge sites and leaf server rows; record what removal affects.
- [ ] 1.2 Owner decision: keep the direct-leaf identity feature (written on every add-on assignment create and update by `SetDirectLeafAccess`, with `:issue_direct_access` storing a gateway-issued certificate and key) on the managed configuration, or remove it; its eligibility gate (active site, connected leaf) is unreachable today.
- [ ] 1.3 List the hub subjects an edge site uses (collectors, agents, rule bucket read) and write the leaf grant.

## 2. Core
- [ ] 2.1 Onboarding package: `nats_leaf` component type with a new `edge_site_id` attribute referencing the edge site (the existing `site` partition alias is left alone and the partition is set as for any other package); a leaf package stores no join token and no bundle.
- [ ] 2.2 Existing download and bundle routes (`POST /api/admin/edge-packages/:id/download`, `POST /api/edge-packages/:id/bundle`) refuse a `nats_leaf` package and record a security event; tests prove a leaf token is neither spent nor turned into an operator actor through them.
- [ ] 2.3 Leaf package transitions: `:bind` (`:issued` to `:bound`, stores the agent id), `:complete` (`:bound` to the existing `:activated`, when the leaf is reported active), `:revoke` and `:expire` keep their existing from-states (`:issued`, `:delivered`) and add `:bound`; add only `:bound` to the status constraint; a leaf package never enters `:delivered`; add a case to `:needs_expiration`, beside the unchanged agent clause, selecting `nats_leaf` packages in `:issued` or `:bound` by `download_token_expires_at` alone (bookkeeping only); agent onboarding behaviour is unchanged.
- [ ] 2.4 Leaf token redemption as dedicated token-gated endpoints, authorized only by the verified leaf token and its package row on every presentation, calling the same core functions as the admin routes with a system actor scoped by the handler to the package's site and registered component: read install context (site, hub readiness, policy public key), register on the named agent, request issuance, read that component's status; never grant `settings.edge.manage` or any RBAC permission; admin edge routes and their permission checks are unchanged and refuse a leaf token; a leaf token always carries the signed instance URL in the envelope's `api` field; on first successful registration store the registered agent id on the onboarding package as the bound identity; make registration idempotent for the same site and stored agent id; refuse and record as a security event any presentation naming another agent id; the status read that observes the leaf active succeeds, returns active and takes `:complete` in that same request, and only presentations after `:activated` are refused; on every presentation refuse and record a token whose `download_token_expires_at` is past, whatever the status (`:issued` or `:bound`), without relying on the `:active` read, `is_usable` or the expiry job; record package and security events.
- [ ] 2.5 Registration accepts only an enrolled agent with a live gateway session.
- [ ] 2.6 Authorizer marks leaf servers connected from the hub connection scan, and disconnected only when its last status is `:connected` and a successful complete pass over every server's connection pages shows the certificate absent; a `:pending` leaf with no session yet stays `:pending`; a failed or partial read leaves the last known status; drop `:provisioned`, `:provision` and `:reprovision` from `NatsLeafServer` so its states are `:pending`, `:connected` and `:disconnected`, with `:connect` legal from `:pending` and `:disconnected`; migrate existing `:provisioned` rows to `:pending`; site status takes `:activate` from `:pending`, `:come_online` from `:offline` and `:go_offline` from `:active`.
- [ ] 2.7 Remove the hard-coded default for the leaf server's `upstream_url`; refuse site creation and token issue without a configured leaf upstream address; refresh the leaf server's `upstream_url` from configuration at token issue; never write `EdgeSite.nats_leaf_url` from hub configuration.
- [ ] 2.8 Replace the leaf's `>` grant with the list from 1.3; broker test proves an edge collector's traffic passes and an outside subject is refused.
- [ ] 2.9 Remove server-side leaf key issuance, credential minting, the provisioning worker and the bundle modules; drop unused attributes by migration.

## 3. Web UI
- [ ] 3.1 Site page: "Deploy leaf" issues a token and shows the one command, the expiry and a revoke action; remove "Download Bundle" and "Regenerate".
- [ ] 3.2 Site list and page show hub readiness and what is missing before a token can be issued.
- [ ] 3.3 Status badges from the real connection state, with "unknown" when the authorizer is not connected.
- [ ] 3.4 Replace "SaaS" wording on the edge site pages.
- [ ] 3.5 Tests for create, issue token, revoke, delete and the refused states.

## 4. CLI and API
- [ ] 4.1 `edge install leaf --token <token>`, with no login, using the leaf endpoints; take the instance from the token's signed URL (https only, except loopback) and the site from the install context; `--instance` is an optional override that must match the token's URL host or the command stops; keep the operator-login form on the admin routes, where `--site` stays required.
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
