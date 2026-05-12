## 1. Catalog Contract

- [ ] 1.1 Define a project-owned catalog module for agent config dependencies.
- [ ] 1.2 Add catalog entry fields for resource module, action classes, config type, compiler/generator, affected-agent resolver, push/invalidation behavior, and secret diagnostics policy.
- [ ] 1.3 Add validation for duplicate entries, unknown config types, missing resolvers, and unsupported push strategies.

## 2. Existing Dependency Coverage

- [ ] 2.1 Register IntegrationSource sync config dependencies, including Armis credentials.
- [ ] 2.2 Register sweep group and mapper config dependencies.
- [ ] 2.3 Register plugin assignment and plugin engine-limit dependencies.
- [ ] 2.4 Register SNMP/sysmon profile dependencies that affect the unified agent config response.

## 3. Dispatcher

- [ ] 3.1 Route resource create/update/destroy notifications through the catalog dispatcher.
- [ ] 3.2 Resolve affected agents through catalog resolvers rather than hard-coded notifier logic.
- [ ] 3.3 Trigger the configured invalidation and connected-agent push behavior for each affected config type.
- [ ] 3.4 Preserve current behavior for resources not yet migrated until all entries are covered.

## 4. Diagnostics

- [ ] 4.1 Record or expose recent config-affecting resource changes with resource, config type, affected agent count, and resulting config version/hash.
- [ ] 4.2 Redact secret values while showing secret presence/fingerprint where useful.
- [ ] 4.3 Add web-ng or CLI diagnostics for why a saved resource did or did not trigger an agent config update.

## 5. Tests

- [ ] 5.1 Add catalog validation tests.
- [ ] 5.2 Add regression coverage proving IntegrationSource updates trigger sync config changes for affected agents.
- [ ] 5.3 Add coverage that generated agent config dependencies are represented in the catalog.
- [ ] 5.4 Add tests proving unaffected agents do not receive scoped config changes.
- [ ] 5.5 Add tests proving diagnostic output redacts secret material.
