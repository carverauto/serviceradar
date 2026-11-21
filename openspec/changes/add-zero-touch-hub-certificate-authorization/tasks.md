## 1. Confirm before building
- [ ] 1.1 Owner decision on the default (design Decision 4).
- [ ] 1.2 No chart-generated certificate carries the subject `O=ServiceRadar`, and a broker experiment on the chart configuration showed only a certificate whose whole subject is exactly `O=ServiceRadar` maps to that static user (other unlisted subjects are refused). Check live deployments for a holder of such a certificate, then remove the user or document it.
- [x] 1.3 Confirm on a disposable broker that nats-server accepts the authorization and accounts blocks from an included file. Confirmed with the embedded server the chart permission tests use: the callout authorization from a top-level include and the AUTH and SYS accounts from an include inside the accounts block are accepted, and empty fragments leave the static configuration unchanged. A change to a fragment still needs a NATS pod restart, as any broker configuration change does today.
- [ ] 1.4 Check live deployments for infrastructure components with recorded certificates (none is known); any found will need re-recording after the subject migration. The demo deployment has none (checked 2026-11-20); others are not checked yet.

## 2. Chart
- [ ] 2.1 Add each chart identity's public certificate to core's runtime certificate projection. A chart render test checks the additions across workloads. Only core gains inventory files, all public certificates, and callout seeds. Only the NATS pod gains the two broker fragments.
- [ ] 2.2 Apply the ownership rule in Decision 2. For a generator-owned signing set, run the signing step on initial generation, certificate regeneration and before the existing-certificates early exit. Verify an empty signing set produces three seeds and two matching fragments together. With three seeds, repair only missing or stale fragments and preserve all five signing entries when both fragments match. Verify that a matching set allows the certificate check to preserve valid certificates or regenerate certificates and write the rotation manifest on a layout upgrade. For any nonempty set missing a seed, including fragments alone, verify the job fails without writes, names each missing seed, and directs the operator to restore it or deliberately remove the remaining signing entries for first provisioning. For supplier-owned sets, leave all five entries to the Secret supplier. Keep the generator Role unchanged.
- [ ] 2.3 Only with enforcement on, project the three issuer Secret seeds into core and the two runtime certificate Secret fragments into the NATS pod. Include the authorization fragment at the top level and the account definitions inside the accounts block.
- [ ] 2.4 Remove `infrastructureAdopted` and the three key values; update chart tests and the values comments. Keep the failure when enforcement is combined with `certs.regenerator.enabled`.
- [ ] 2.5 Broker test: nats-server boots from the rendered configuration with enforcement on, and each chart identity connects through a callout answered by a test authorizer.
- [ ] 2.6 Render settings for core: one from `nats.certificateAuthorization.enabled` saying enforcement is configured, and one from `nats.leafnodes.enabled` together with enforcement saying the hub broker has the leafnodes listener; a chart test covers each combination.
- [ ] 2.7 Document the five required keys for supplier-owned sets under Decision 2, including a shared Secret with generation disabled. The supplier provides three seeds in the issuer Secret and two matching public fragments in the runtime Secret before enabling enforcement. Only the hosted inventory certificate list is configurable and defaults to empty. A missing listed inventory certificate blocks core startup. Verify the fixed signing projections are omitted with enforcement off. With enforcement on, omit each seed in turn and check that core starts and hub status reports `signing keys not provisioned`. Verify leaf install stops on the missing seed before host changes. Omit either fragment and restart one broker. Check that Kubernetes names the missing key in that pod's mount error regardless of core's seeds. With a seed also missing and core disconnected, verify that hub status still reports `signing keys not provisioned`. On an otherwise ready hub, verify status stays ready and leaf install proceeds while core answers through a surviving broker. With all seeds mounted, verify that losing the authorizer connection yields the authorizer-not-answering status and stops leaf install before host changes. Document the mount error and NATS pod event check in the runbook.

## 3. Core
- [ ] 3.1 Migration: add a subject to the certificate record; write it from the PEM whenever a certificate is recorded (inventory adoption, hand adoption, successor and rotation recording). Existing rows stay without a subject.
- [ ] 3.2 First adoption from the inventory, one ordered rule: step 1, while any infrastructure certificate row lacks a subject, adopt nothing and report the remedy; step 2, otherwise verify chain, validity, chart-identity subject present in the static users file, and revocation (a failed check is reported and nothing is written), and for a qualifying certificate whose subject is not held (no recorded certificate carries it, revoked or not), create the component with a component id derived from the subject only and that subject's static grant as its stored permissions, and record the certificate; when the subject is held, write nothing (replacement stays with `RuntimeCertificateRotation`, unchanged). Report coverage: adopted when the inventory's certificate is recorded and not revoked, otherwise the reason.
- [ ] 3.3 Tests: a revoked then regenerated chart identity is recorded by neither path, no second component exists, and the subject is reported with the reason; a rotation naming an unrecorded predecessor leaves the identity reported unadopted; a legacy row without a subject blocks adoption.
- [ ] 3.4 Use mounted chart seeds and log once when a stored signing record is unused. After upgrading from API bootstrap, verify core answers with the mounted seeds while at least one broker is serving and core's authorizer is connected, even when the stored keys differ. Reserve the stored keys and bootstrap API for installs without a chart.
- [ ] 3.5 Report hub readiness from core (enforcement configured, authorizer answering with reason, chart identity coverage, leaf listener).
- [ ] 3.6 In web-ng, decide `leaf_upstream_url` from the application env read without a default (the hosted fallback is not configured) and assemble the `hub` object on the bootstrap route from core's fields and that one.

## 4. CLI
- [ ] 4.1 `edge hub status`.
- [ ] 4.2 `edge install leaf` stops before any host change when the hub status is missing or unreadable or the hub cannot accept the leaf, in the design's check order with each cause's resolver; collector installs keep today's behaviour.
- [ ] 4.3 Publish the CLI release that carries both.

## 5. Verify on the demo deployment

Check authentication, reconnection and admission while at least one broker is serving and core's authorizer is connected.

- [ ] 5.1 With enforcement off, every chart identity is reported adopted.
- [ ] 5.2 With the signing seeds present and all chart identities adopted, turn enforcement on; every client reconnects; the broker logs no refusal for a chart identity.
- [ ] 5.3 Regenerate one adopted certificate; the existing rotation path records the replacement, the inventory writes nothing for it, and the client is admitted again without operator action.
- [ ] 5.4 Create an edge site and install a leaf with the CLI on a lab host; the leaf connects. This is this change's leaf-connect check only; it supplies the leaf that task 2.1 of `refactor-collectors-onto-shared-ingest-pipeline` still has to exercise, and does not close that task.
- [ ] 5.5 Turn enforcement off again and confirm clients are unaffected.

## 6. Documentation and follow-up
- [ ] 6.1 Rewrite the enablement section of `docs/managed-component-certificates.md`.
- [ ] 6.2 File the `serviceradar-control` change for hosted tenants.
