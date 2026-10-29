# Implementation plan

The user approved per-replica persistent storage through an opt-in StatefulSet.
Runtime member-identity selection and the isolated filesystem initializer are
implemented. The installation inventory and conversion contracts are specified;
the read-only API association check is implemented. Inventory enforcement,
physical-volume qualification, exclusive Job packaging and deployment acceptance
remain open.

## 1. Confirm design

- [x] 1.1 Select per-replica StatefulSet storage; the user approved this architecture over the single-core demo alternative.
- [ ] 1.1a Obtain approval for the initial conversion maintenance window.
- [ ] 1.2 Verify qualified CSI ReadWriteOncePod support, PV retention and encryption for the intended installation.
- [x] 1.3 Specify the bounded installation-document schema, volume inventory association and guarded controller-kind conversion/rollback protocol; see [inventory](installation-inventory.md) and [conversion](conversion-protocol.md). These are implementation contracts, not installed enforcement.

## 2. Runtime identity and explicit provisioning

- [x] 2.1 Add the versioned per-member identity resolver with scalar-mode compatibility and ambiguity refusal; see [configuration contract](identity-configuration.md).
- [x] 2.2 Package a bounded, explicit filesystem provisioning entry point without starting core or accessing credentials; see [initializer contract](../../../docs/camera-spool-initialization.md).
- [x] 2.3 Exercise real resolver/filesystem success, exact retry, conflicting identity, substituted volume and partial marker refusal; preserve the existing worker ownership assertions. The release-process and retained storage tests cover this local boundary; physical-volume attestation remains task 3.2.

## 3. Chart packaging and migration

- [x] 3.0 Preserve an explicit zero core replica count so an operator-requested drain is not rendered as one replica; this does not prove retirement or authorize conversion.
- [ ] 3.1 Add the opt-in StatefulSet, per-member retained claims and installed identity document; preserve the default Deployment.
- [ ] 3.2 Add an explicitly invoked provisioning Job and actual-volume preflight with recording disabled.
- [x] 3.2a Add the bounded read-only Kubernetes volume-association command; see [preflight](../../../docs/camera-spool-preflight.md). API observation does not establish mount exclusivity, encryption, initialization authority or recording readiness.
- [ ] 3.3 Implement the independent admission fence and guarded conversion/rollback procedure, including interrupted conversion, stale Helm revisions, scale subresources and refusal of concurrent old/new owners.
- [ ] 3.4 Validate rendered manifests and synthetic cluster replacement, exclusive mount, scaling and uninstall preservation.

## 4. Cloud scope

- [x] 4.1 Extend [Cloud #182](https://github.com/carverauto/serviceradar-control/issues/182#issuecomment-6483971547) and [Cloud #183](https://github.com/carverauto/serviceradar-control/issues/183#issuecomment-6483972071) with retained spool inventory, initialization and preservation workflow; [Cloud #190](https://github.com/carverauto/serviceradar-control/issues/190#issuecomment-6483972642) carries controller-aware restore scope. Implementation remains open.
- [ ] 4.2 Materialize compatible chart/configuration revisions with per-member observed status and admission budgets.
- [ ] 4.3 Complete [Cloud #190](https://github.com/carverauto/serviceradar-control/issues/190): update both restore plan and execution for the installed controller kind; test Deployment, StatefulSet and ambiguous/unknown refusal.
- [ ] 4.4 Verify suspend/resume, scale-down, termination and database restore retain the correct volume lifetimes and unresolved state.

## 5. Validation and delivery

- [ ] 5.1 Run appropriate remote Bazel/guarded database tests and full make test for each implementation pass; preserve every assertion.
- [ ] 5.2 Deliver each PR through no-mistakes using Treehouse checkouts with ignored remote Bazel configuration.
- [ ] 5.3 After synthetic acceptance and explicit installation approval, run one bounded local capture with independent viewer continuity and preserved private evidence.
- [ ] 5.4 Complete provider qualification and fresh per-purpose archive authorities before upload/publication/replay acceptance. Keep continuous recording disabled until its own implementation and acceptance.
