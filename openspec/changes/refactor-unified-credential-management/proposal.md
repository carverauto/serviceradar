# Change: Refactor credential management into a unified settings experience

## Why
ServiceRadar now has several credential entry points with different language and storage paths: plugin credential rules, AWX controller tokens, SNMP discovery/profile credentials, mapper/discovery credentials, and remote-access credentials. Operators should not need to know whether a value is a "broker secret UUID" or which subsystem originally created it. The current `Settings -> Networks -> Credentials` flow mixes a package-driven catalog with provider names and forms hard-coded in LiveView, while other consumers still maintain separate credential stores and screens.

## What Changes
- Replace provider-specific credential menus and forms with one provider-neutral credential management area that lists credentials, rules, and consumers together.
- Build one validated credential descriptor catalog from approved integration packages. Wasm-backed providers SHALL publish their complete credential and runtime contract in their signed package manifest; they SHALL NOT be registered as native profiles. Provider names, auth methods, field labels, defaults, documentation, supported purposes, consumers, grants, and public parameter templates SHALL be descriptor data rather than branches or allowlists in core/web-ng.
- Keep only a bounded platform vocabulary for credential primitives and field controls, such as token, username/password, SSH key, certificate, SNMP, text, password, and textarea.
- Allow creating or rotating encrypted secret material inline from the same form that binds a credential rule, while preserving the existing advanced path of selecting an existing secret.
- Make this catalog and settings area canonical for plugin HTTP access, SNMP polling and traps, mapper/discovery, AWX, remote access, and future credential consumers.
- Add first-class credential management actions for public-metadata edits, write-only rotation, and permanent deletion when no configured consumer or live broker grant uses the credential.
- Make usage summaries navigable, including direct links from a reusable credential to the SNMP profiles and credential rules that reference it.
- Enforce the no-consumer deletion invariant in PostgreSQL with restrictive foreign keys and FK-backed bindings for legacy text/JSON references so UI checks, APIs, and concurrent writes cannot bypass it.
- Update copy, validation, defaults, and documentation links so credential rules are presented as a platform-wide credential routing system.
- Define a compatibility migration for existing credential rules, AWX tokens, SNMP profiles, and consumer-local secrets so current installs keep working without re-entry.

## Impact
- Affected specs: credential-management, build-web-ui, network-discovery, snmp-checker, plugin-configuration-ui, agent-config
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/network_credential_rules_live.ex`, credential Ash resources, Ansible controller forms, SNMP/discovery credential surfaces, plugin secret-reference UI, docs under `docs/docs/`
- Security impact: keeps encrypted-at-rest and broker-grant boundaries, removes provider code from the browser path, and broadens the UI surface that can create, rotate, and permanently delete credential records; requires strict descriptor validation, redaction, fresh event authorization, database-enforced consumer protection, and deletion of ciphertext-bearing version rows.
