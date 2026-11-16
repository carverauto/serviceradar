## 1. Built-in templates
- [x] 1.1 Fixed ids and poll-correct modes (GET for `.0` scalars, walk for IF-MIB columns) on the Standard templates; add System Uptime and Interface Counters
- [x] 1.2 `SNMPOIDTemplate` `:seed_builtin` create action, system actor only
- [x] 1.3 `BuiltinTemplates.seed/1` (create missing by id, skip and log a conflicting operator template) and `BuiltinTemplateSeeder` coordinator child

## 2. Default profile
- [x] 2.1 Migration attaches System Uptime and Interface Counters to a default profile with no templates
- [x] 2.2 Same migration creates the starter profile on a baselined install that never received it
- [x] 2.3 Bump `core.migrations.expectedVersion`

## 3. Profiles that poll nothing
- [x] 3.1 `MissingOIDs` predicate shared by the compiler and settings
- [x] 3.2 Compiler emits `[:serviceradar, :snmp, :profile_without_oids]` and logs once per change through `WarningLedger`
- [x] 3.3 Settings list **No OIDs** badge

## 4. Settings form
- [x] 4.1 Profile form lists database templates (built-in and custom) by id
- [x] 4.2 Template browser carries walk mode into copied OIDs

## 5. Tests and docs
- [x] 5.1 Compiler: no-OID report and its clearing (fail-first); built-in templates compile walked counters
- [x] 5.2 Seeding: fixed ids, idempotent, operator template kept, system-only action
- [x] 5.3 web-ng: **No OIDs** badge (fail-first); form attaches a built-in template by id
- [x] 5.4 Migration SQL verified on a scratch database for all four cases
- [x] 5.5 `docs/docs/snmp.md`
