## 1. Confirm before building
- [ ] 1.1 Owner decision on the default (design Decision 4).
- [ ] 1.2 No chart-generated certificate carries the subject `O=ServiceRadar`, and a broker experiment on the chart configuration showed only a certificate whose whole subject is exactly `O=ServiceRadar` maps to that static user (other unlisted subjects are refused). Check live deployments for a holder of such a certificate, then remove the user or document it.
- [ ] 1.3 Confirm on a disposable broker that nats-server accepts the authorization and accounts blocks from an included file, and what a rollout needs when that file changes.

## 2. Chart
- [ ] 2.1 Generator writes the public certificate inventory ConfigMap; a chart test proves it contains no private key.
- [ ] 2.2 Generator creates the callout nkeys once, the seed Secret and the public broker fragment; rerunning it changes nothing.
- [ ] 2.3 NATS pod includes the fragment; core mounts the inventory and the seeds; no other pod mounts the seeds.
- [ ] 2.4 Remove `infrastructureAdopted` and the three key values; update chart tests and the values comments.
- [ ] 2.5 Broker test: nats-server boots from the rendered configuration with enforcement on, and each chart identity connects through a callout answered by a test authorizer.
- [ ] 2.6 Render a setting for core, from `nats.leafnodes.enabled` together with enforcement, that says the hub broker has the leafnodes listener; a chart test covers each combination.

## 3. Core
- [ ] 3.1 Reconcile chart identities from the inventory: verify chain, validity, subject and revocation; adopt (create the component with the static grant) when no component holds the subject; record a successor when a component holds it with an adopted predecessor.
- [ ] 3.2 Read signing keys from mounted files; report a conflict with a stored record and refuse to answer.
- [ ] 3.3 Report hub readiness from core (enforcement, chart identity coverage, leaf listener).
- [ ] 3.4 In web-ng, decide `leaf_upstream_url` from the application env read without a default (the hosted fallback is not configured) and assemble the `hub` object on the bootstrap route from core's fields and that one.

## 4. CLI
- [ ] 4.1 `edge hub status`.
- [ ] 4.2 `edge install leaf` stops before any host change when the hub cannot accept the leaf.
- [ ] 4.3 Publish the CLI release that carries both.

## 5. Verify on the demo deployment
- [ ] 5.1 With enforcement off, every chart identity is reported adopted.
- [ ] 5.2 Turn enforcement on; every client reconnects; the broker logs no refusal for a chart identity.
- [ ] 5.3 Regenerate one certificate; the client is admitted again without operator action.
- [ ] 5.4 Create an edge site and install a leaf with the CLI on a lab host; the leaf connects. This is this change's leaf-connect check only; it supplies the leaf that task 2.1 of `refactor-collectors-onto-shared-ingest-pipeline` still has to exercise, and does not close that task.
- [ ] 5.5 Turn enforcement off again and confirm clients are unaffected.

## 6. Documentation and follow-up
- [ ] 6.1 Rewrite the enablement section of `docs/managed-component-certificates.md`.
- [ ] 6.2 File the `serviceradar-control` change for hosted tenants.
