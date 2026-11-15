# Proposal: ship standard SNMP OID templates and report profiles that poll nothing

## Problem

An enabled SNMP profile can select thousands of devices and poll none of them,
with nothing anywhere to say so.

`SNMPCompiler.compile_query_targets/5` builds a target for a device its target
query selects only from the OIDs of the profile's `oid_template_ids`. With no
OIDs it returns no query targets, and nothing is logged, counted or shown. The
starter "Default SNMP" profile is exactly that profile: the seed migration
(`20260903000000_seed_default_snmp_profile_once.exs`) writes it with no
templates, and no install has any template rows to attach:

1. **The built-in templates never reach the database.**
   `BuiltinTemplates.seed!/1` has no caller, and it could not work if called:
   the `:create` action forces `is_builtin: false` and does not accept it.
2. **The profile form cannot attach a built-in template.** It lists the
   in-code catalog under slug ids (`standard-interface-statistics`), and
   `oid_template_ids` is a `uuid[]`, so selecting one fails the save.
3. **The standard templates could not be polled through a profile anyway.**
   Their IF-MIB OIDs are table columns read with a GET, which returns
   `noSuchObject`; the agent then marks the whole target unavailable.
4. **A fresh install has no default profile at all.** The schema baseline is a
   schema-only dump that records the seed migration as applied without its
   row, so the seed never runs on a database created from the baseline.

Observed on a demo deployment: a default profile whose target query selects
about 6,300 devices compiles only its 25 explicit targets.

## What this changes

1. **Standard templates are product data.** The Standard vendor templates get
   fixed ids and are poll-correct: scalars (`.0`) are read with a GET, IF-MIB
   columns are walked. `BuiltinTemplateSeeder` (a coordinator seeder, like the
   rule and notification template seeders) writes any that are missing, under
   a system-only `:seed_builtin` action. Existing rows are never rewritten, and
   an operator template with the same vendor and name is left alone. Two new
   templates are what the default profile polls:
   - **System Uptime**: `sysUpTime` (`.1.3.6.1.2.1.1.3.0`), gauge, seconds.
   - **Interface Counters** (walked): `ifHCInOctets`, `ifHCOutOctets`,
     `ifHCInUcastPkts`, `ifHCOutUcastPkts` (the same IF-MIB 64-bit OIDs the
     interface-selection path already polls for explicit targets), plus
     `ifInErrors`, `ifOutErrors`, `ifInDiscards`, `ifOutDiscards` and
     `ifOperStatus`.
   The vendor templates stay a browsing catalog and are not seeded: several of
   their OIDs are table columns without a walk mode.
2. **The default profile polls them.** A migration attaches the two templates
   to the default profile when its template list is empty, and creates the
   starter profile on a database built from a baseline that swallowed the seed.
   A non-empty template list is the operator's choice and is never touched.
   Attaching is right for existing installs: an empty default profile is a
   no-op nobody chose, because there was never a template to choose.
3. **A profile that selects devices it cannot poll is reported, not refused.**
   Same three-surface shape as the target limit, minus save-time refusal:
   - compile: a `[:serviceradar, :snmp, :profile_without_oids]` telemetry
     event on every such compile and a core warning when the condition starts
     or the query changes (`WarningLedger`);
   - settings: a persistent **No OIDs** badge in the SNMP profile list;
   - save: not refused. A template can be destroyed or emptied after a profile
     is saved, so a save check could not keep the state away, and refusing
     saves would block every existing profile in that state from being edited.
4. **The profile form lists the database templates** (built-in and custom) by
   their real ids, so a built-in template can be attached.

## Impact

- Affected spec: `snmp-checker` (three ADDED requirements).
- Affected code: `SNMPProfiles.BuiltinTemplates`, `SNMPOIDTemplate`
  (`:seed_builtin`), new `BuiltinTemplateSeeder` and `MissingOIDs`,
  `SNMPCompiler`, the web-ng SNMP profile list and form, one migration.
- Deployments: every enabled default profile with no templates starts walking
  the interface table of every device its query selects, from the agents it
  is pinned to (or every agent). Review the default profile's target query
  before upgrading an install whose inventory holds devices that should not be
  polled.
