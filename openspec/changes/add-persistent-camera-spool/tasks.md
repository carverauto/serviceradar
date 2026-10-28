# Implementation plan

The user approved per-replica persistent storage through an opt-in StatefulSet.
All implementation, qualification and deployment acceptance work remains open.

## 1. Confirm design

- [x] 1.1 Select per-replica StatefulSet storage; the user approved this architecture over the single-core demo alternative.
- [ ] 1.1a Obtain approval for the initial conversion maintenance window.
- [ ] 1.2 Verify qualified CSI ReadWriteOncePod support, PV retention and encryption for the intended installation.
- [ ] 1.3 Specify the bounded installation-document schema, volume inventory association and guarded controller-kind conversion/rollback protocol.

## 2. Runtime identity and explicit provisioning

- [ ] 2.1 Add the versioned per-member identity resolver with scalar-mode compatibility and ambiguity refusal.
- [ ] 2.2 Package a bounded, explicit filesystem provisioning entry point without starting core or accessing credentials.
- [ ] 2.3 Exercise real resolver/filesystem success, exact retry, conflicting identity, substituted volume and partial marker refusal; preserve the existing worker ownership assertions.

## 3. Chart packaging and migration

- [ ] 3.1 Add the opt-in StatefulSet, per-member retained claims and installed identity document; preserve the default Deployment.
- [ ] 3.2 Add an explicitly invoked provisioning Job and actual-volume preflight with recording disabled.
- [ ] 3.3 Implement the guarded conversion and rollback procedure, including interrupted conversion and refusal of concurrent old/new owners.
- [ ] 3.4 Validate rendered manifests and synthetic cluster replacement, exclusive mount, scaling and uninstall preservation.

## 4. Cloud scope

- [ ] 4.1 Extend issues #182/#183 with retained spool inventory, initialization and preservation workflow.
- [ ] 4.2 Materialize compatible chart/configuration revisions with per-member observed status and admission budgets.
- [ ] 4.3 Complete [Cloud #190](https://github.com/carverauto/serviceradar-control/issues/190): update both restore plan and execution for the installed controller kind; test Deployment, StatefulSet and ambiguous/unknown refusal.
- [ ] 4.4 Verify suspend/resume, scale-down, termination and database restore retain the correct volume lifetimes and unresolved state.

## 5. Validation and delivery

- [ ] 5.1 Run appropriate remote Bazel/guarded database tests and full make test for each implementation pass; preserve every assertion.
- [ ] 5.2 Deliver each PR through no-mistakes using Treehouse checkouts with ignored remote Bazel configuration.
- [ ] 5.3 After synthetic acceptance and explicit installation approval, run one bounded local capture with independent viewer continuity and preserved private evidence.
- [ ] 5.4 Complete provider qualification and fresh per-purpose archive authorities before upload/publication/replay acceptance. Keep continuous recording disabled until its own implementation and acceptance.

