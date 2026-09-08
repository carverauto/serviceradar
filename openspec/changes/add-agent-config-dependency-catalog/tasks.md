## 1. Catalog Contract

- [x] 1.1 Define a project-owned catalog module for agent config dependencies.
- [x] 1.2 Add catalog entry fields for resource module, action classes, config type, compiler/generator, affected-agent resolver, push/invalidation behavior, and secret diagnostics policy.
- [x] 1.3 Add validation for duplicate entries, unknown config types, missing resolvers, and unsupported push strategies.

## 2. Existing Dependency Coverage

- [x] 2.1 Register IntegrationSource sync config dependencies, including Armis credentials.
- [x] 2.2 Register sweep group and mapper config dependencies.
- [x] 2.3 Register plugin assignment and plugin engine-limit dependencies.
- [x] 2.4 Register SNMP/sysmon profile dependencies that affect the unified agent config response.

## 3. Dispatcher

- [x] 3.1 Route resource create/update/destroy notifications through the catalog dispatcher.
- [x] 3.2 Resolve affected agents through catalog resolvers rather than hard-coded notifier logic.
- [x] 3.3 Trigger the configured invalidation and connected-agent push behavior for each affected config type.
- [x] 3.4 Preserve current behavior for resources not yet migrated until all entries are covered.

## 4. Diagnostics

- [x] 4.1 Record or expose recent config-affecting resource changes with resource, config type, affected agent count, and resulting config version/hash.
- [x] 4.2 Redact secret values while showing secret presence/fingerprint where useful.
- [x] 4.3 Add web-ng or CLI diagnostics for why a saved resource did or did not trigger an agent config update.

## 5. Tests

- [x] 5.1 Add catalog validation tests.
- [x] 5.2 Add regression coverage proving IntegrationSource updates trigger sync config changes for affected agents.
- [x] 5.3 Add coverage that generated agent config dependencies are represented in the catalog.
- [x] 5.4 Add tests proving unaffected agents do not receive scoped config changes.
- [x] 5.5 Add tests proving diagnostic output redacts secret material.
