## 1. Confirm before building
- [ ] 1.1 Owner decision on the default (design Decision 4).
- [ ] 1.2 No chart-generated certificate carries the subject `O=ServiceRadar`, and a broker experiment on the chart configuration showed only a certificate whose whole subject is exactly `O=ServiceRadar` maps to that static user (other unlisted subjects are refused). Check live deployments for a holder of such a certificate, then remove the user or document it.
- [x] 1.3 Confirm on a disposable broker that nats-server accepts the authorization and accounts blocks from an included file. Confirmed with the embedded server the chart permission tests use: the callout authorization from a top-level include and the AUTH and SYS accounts from an include inside the accounts block are accepted, and empty fragments leave the static configuration unchanged. A change to a fragment still needs a NATS pod restart, as any broker configuration change does today.
- [ ] 1.4 Check live deployments for infrastructure components with recorded certificates (none is known); any found will need re-recording after the subject migration. The demo deployment has none (checked 2026-11-20); others are not checked yet.

## 2. Chart
- [ ] 2.1 Core's runtime certificate projection gains the public certificate of each chart identity; a chart test proves the list names no private key and that no other workload's list changes.
- [ ] 2.2 Generator creates the callout nkeys once and stores the seeds and the two public broker fragments as keys of the runtime certificate Secret, including on the path where certificates already exist; rerunning it changes nothing.
- [ ] 2.3 With enforcement on, the NATS pod projects and includes the fragments and core projects the seeds; a chart test proves no other workload's projection names the seeds.
- [ ] 2.4 Remove `infrastructureAdopted` and the three key values; update chart tests and the values comments. Keep the failure when enforcement is combined with `certs.regenerator.enabled`.
- [ ] 2.5 Broker test: nats-server boots from the rendered configuration with enforcement on, and each chart identity connects through a callout answered by a test authorizer.
- [ ] 2.6 Render settings for core: one from `nats.certificateAuthorization.enabled` saying enforcement is configured, and one from `nats.leafnodes.enabled` together with enforcement saying the hub broker has the leafnodes listener; a chart test covers each combination.
- [ ] 2.7 Hosted mode: the projected certificate files and the callout keys come from a chart value the control plane sets to what its Secret carries; by default nothing is projected there, so a missing key cannot stop core or NATS from starting. Check the control plane's Secret before enabling it for a tenant.

## 3. Core
- [ ] 3.1 Migration: add a subject to the certificate record; write it from the PEM whenever a certificate is recorded (inventory adoption, hand adoption, successor and rotation recording). Existing rows stay without a subject.
- [ ] 3.2 First adoption from the inventory, one ordered rule: step 1, while any infrastructure certificate row lacks a subject, adopt nothing and report the remedy; step 2, otherwise verify chain, validity, chart-identity subject present in the static users file, and revocation (a failed check is reported and nothing is written), and for a qualifying certificate whose subject is not held (no recorded certificate carries it, revoked or not), create the component with a component id derived from the subject only and that subject's static grant as its stored permissions, and record the certificate; when the subject is held, write nothing (replacement stays with `RuntimeCertificateRotation`, unchanged). Report coverage: adopted when the inventory's certificate is recorded and not revoked, otherwise the reason.
- [ ] 3.3 Tests: a revoked then regenerated chart identity is recorded by neither path, no second component exists, and the subject is reported with the reason; a rotation naming an unrecorded predecessor leaves the identity reported unadopted; a legacy row without a subject blocks adoption.
- [ ] 3.4 Read signing keys from mounted files; report a conflict with a stored record and refuse to answer.
- [ ] 3.5 Report hub readiness from core (enforcement configured, authorizer answering with reason, chart identity coverage, leaf listener).
- [ ] 3.6 In web-ng, decide `leaf_upstream_url` from the application env read without a default (the hosted fallback is not configured) and assemble the `hub` object on the bootstrap route from core's fields and that one.

## 4. CLI
- [ ] 4.1 `edge hub status`.
- [ ] 4.2 `edge install leaf` stops before any host change when the hub status is missing or unreadable or the hub cannot accept the leaf, in the design's check order with each cause's resolver; collector installs keep today's behaviour.
- [ ] 4.3 Publish the CLI release that carries both.

## 5. Verify on the demo deployment
- [ ] 5.1 With enforcement off, every chart identity is reported adopted.
- [ ] 5.2 Turn enforcement on; every client reconnects; the broker logs no refusal for a chart identity.
- [ ] 5.3 Regenerate one adopted certificate; the existing rotation path records the replacement, the inventory writes nothing for it, and the client is admitted again without operator action.
- [ ] 5.4 Create an edge site and install a leaf with the CLI on a lab host; the leaf connects. This is this change's leaf-connect check only; it supplies the leaf that task 2.1 of `refactor-collectors-onto-shared-ingest-pipeline` still has to exercise, and does not close that task.
- [ ] 5.5 Turn enforcement off again and confirm clients are unaffected.

## 6. Documentation and follow-up
- [ ] 6.1 Rewrite the enablement section of `docs/managed-component-certificates.md`.
- [ ] 6.2 File the `serviceradar-control` change for hosted tenants.
