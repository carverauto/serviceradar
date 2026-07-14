## 1. Generic package contract
- [x] 1.1 Add and validate bounded package-owned integration descriptors for documentation, credentials, provisioning, inventory sources, and display fields.
- [x] 1.2 Build the runtime catalog from approved package versions, reject duplicate provider/source claims, and reserve core-owned credential providers.
- [x] 1.3 Extend the supported JSON Schema subset for nested object arrays, local definitions, object bounds, and dependent fields.
- [x] 1.4 Import bounded conventional package resources and verify that declared documentation exists in the signed bundle.

## 2. Generic credentials and operator UI
- [x] 2.1 Replace the provider-specific profile and provisioner with descriptor-driven credential-rule reconciliation.
- [x] 2.2 Materialize package assignments and bind the descriptor-selected producer schedule and credential requirement without plaintext secrets.
- [x] 2.3 Render provider options, auth methods, purposes, target scope, schema fields, cadence, diagnostics, and Run Now from approved package data.
- [x] 2.4 Render inventory source labels and metadata fields from package descriptors rather than static core catalogs.
- [x] 2.5 Add generic fixtures proving multiple external providers coexist without provider registration in core.

## 3. Inventory and DIRE
- [x] 3.1 Accept complete bounded snapshots from any valid inventory source and retain source object, integration, collection, and freshness identity.
- [x] 3.2 Persist only bounded nested `source_metadata` as provider-owned observation data and keep canonical identity fields generic.
- [x] 3.3 Preserve all discovery sources and existing canonical source identity during cross-source convergence.
- [x] 3.4 Add generic source-observation, absence, idempotency, merge, conflict, and collection-consistent pagination coverage.
- [x] 3.5 Require typed `source` and `instance` filters on the authenticated source-inventory API and retain SQL-safe bounded pagination.

## 4. External release and plugin ownership
- [x] 4.1 Replace the one-off release workflow with a repository/tag-parameterized external Wasm workflow and generic contract tests.
- [x] 4.2 Remove provider documentation, static SRQL fields, provider profiles, and provider-specific host integration tests from core.
- [x] 4.3 Rename the first plugin and product language to OpenText Network Automation and ship its schema, descriptor, docs, metadata mapping, and tests in its repository.
- [x] 4.4 Build deterministic TinyGo artifacts, package provider resources, and run plugin unit/reproducibility checks.

## 5. Core validation
- [x] 5.1 Compile core and web-ng with warnings as errors.
- [x] 5.2 Run database-free manifest, schema, catalog, provisioner, discovery, and source-reader tests.
- [ ] 5.3 Run data-backed core/web-ng integration tests in the repository database harness.
- [x] 5.4 Run targeted Go, Rust, workflow, bundle-validator, and OpenSpec checks.
- [ ] 5.5 Complete full CI and security scanning on the feature branch.

## 6. Publish and operate the first external plugin
- [ ] 6.1 Create the external Forgejo repository and push the plugin feature branch.
- [ ] 6.2 Merge and tag the plugin, then sign and publish its bundle through the protected generic workflow.
- [ ] 6.3 Import and approve the package, assign it to the selected `example-namespace` agent, and create its scoped credential rule.
- [ ] 6.4 Compare one manual collection with a current product export and inspect DIRE convergence/conflict samples.
- [ ] 6.5 Enable the daily schedule, verify two collections plus Run Now, and audit all outputs for credential/token leakage.
