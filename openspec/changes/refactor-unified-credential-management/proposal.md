# Change: Refactor credential management into a unified settings experience

## Why
ServiceRadar now has several credential entry points with different language and storage paths: Proxmox credential rules, AWX controller tokens, SNMP discovery/profile credentials, plugin secret references, and mapper/discovery credentials. Operators should not need to know whether a value is a "broker secret UUID" or whether a rule was originally created for Proxmox. The current `Settings -> Networks -> Credentials` flow is provider-biased, exposes free-text provider/auth fields, links to overly narrow docs, and forces users to create a secret separately before binding it to a rule.

## What Changes
- Replace the Proxmox-biased credential rules UX with a provider-neutral credential management area that lists credentials and credential rules together.
- Introduce typed provider/auth presets for supported integrations such as Proxmox, AWX/Ansible, SNMP, SSH, HTTP API token, username/password, certificate, and generic opaque secrets.
- Allow creating or rotating encrypted secret material inline from the same form that binds a credential rule, while preserving the existing advanced path of selecting an existing secret.
- Update copy, validation, defaults, and documentation links so credential rules are presented as a platform-wide credential routing system rather than a Proxmox-only feature.
- Define a migration path for existing Proxmox credential rules and secrets so current installs keep working without re-entry.

## Impact
- Affected specs: credential-management, build-web-ui, network-discovery, snmp-checker, plugin-configuration-ui, agent-config
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/network_credential_rules_live.ex`, credential Ash resources, Ansible controller forms, SNMP/discovery credential surfaces, plugin secret-reference UI, docs under `docs/docs/`
- Security impact: keeps encrypted-at-rest and broker-grant boundaries, but broadens the UI surface that can create credential records; requires strict redaction and provider-specific validation.
