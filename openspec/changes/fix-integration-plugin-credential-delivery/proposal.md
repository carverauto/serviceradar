# Change: Fix integration plugin credential delivery and sandbox egress

## Why

Every credential-backed integration plugin in the demo deployment is failing, and
none of the failures is a missing credential. All thirteen rows in
`platform.network_credential_secrets` are already `source_type =
internal_encrypted`, the Helm chart carries zero integration credentials, and the
AWX controller reports `AWX 24.6.1 reachable`. The credentials are in the
database exactly as intended; the delivery path around them is broken in five
independent places, and each failure is reported to the operator as something
other than what it is.

1. **The Wasm sandbox denies literal-IP egress.** `allowsHTTPHost/1` deliberately
   refuses to let an `allowed_domains: ["*"]` wildcard expand to an IP literal and
   falls through to `allowed_networks`, which only the NetBox manifest declares.
   UniFi Protect, Axis, and OpenText target on-prem appliances that are almost
   always addressed by private IP, so every request is denied before any socket
   is opened. The operator sees `UniFi Protect: 0 cameras, 0 streams` while the
   real cause, `host error -2 (http_request)`, is buried in `details`.

2. **UniFi Protect and Axis credential rules cannot be saved.** The TLS Policy
   control renders only when the selected auth method declares a non-empty
   `tls_policies` list, but `normalize_rule_params/2` requires a valid
   `tls_policy` param unconditionally. Neither manifest declares the key, so the
   input is never rendered, the browser submits nothing, and the save fails 100%
   of the time with `Invalid TLS policy`. Core disagrees with the UI here:
   `allowed?(_value, [])` returns `true`, meaning an undeclared list already means
   "any policy permitted" everywhere except the form.

3. **Proxmox inventory enrichment is fail-closed on TLS and has no way to
   comply.** `validate_rule_transport/2` requires exactly
   `{"proxmox_api_token", "verify"}` and there is no CA-bundle or fingerprint
   field anywhere in the credential rule, so an operator whose Proxmox VE node
   presents its default self-signed certificate cannot satisfy the check without
   weakening it. Both demo rules are `skip_verify`, so every enrichment is
   rejected and no `proxmox` broker grant has ever been minted.

4. **The AWX bridge runs a scheduled check it can never satisfy.** The `awx`
   package is a command bridge; its token arrives per-dispatch. But any
   assignment without the `action-only:v1` capability also gets a 60s periodic
   runner that invokes `run_check` with the assignment's own params, which hold no
   token by design. That scheduled run fails forever with `api_token is required`.

5. **NetBox has no credential surface at all.** Its manifest declares no
   `integrations.credential_profiles`, so it cannot appear in the credential UI,
   and its API token is designed to sit in plaintext in
   `plugin_assignments.params`. This is a direct violation of the DB-only
   credential policy, and the empty `params` is why it reports
   `has no sources configured`.

Two genuine environment-sourced credential paths also remain: the VulnCheck feed
falls back to `VULNCHECK_API_TOKEN`, and the Go agent still loads SNMP community
strings and v3 passwords from `/etc/serviceradar/snmp.json`.

Finally, there is no credentials document anywhere in `docs/docs/`. The four
integration pages that mention credential rules call the same page four different
names, and three of them document behaviour that is now wrong.

## What Changes

- Wasm plugin manifests that target on-prem appliances SHALL declare the private
  address space they are permitted to reach, and the agent SHALL surface an
  egress denial as a distinguishable, operator-legible error rather than an empty
  result.
- The credential rule form SHALL render a TLS policy control whenever the
  provider declares transport controls, defaulting to the full policy set when the
  auth method does not narrow it — matching what core already enforces. This makes
  the existing `skip_verify` value reachable from the UI.
- Credential rules SHALL accept operator-supplied CA trust material (a PEM bundle
  or a certificate fingerprint) so a provider that mandates `verify` can be used
  against an appliance with a private or self-signed certificate. Proxmox
  inventory enrichment keeps its `verify` requirement.
- The AWX bridge SHALL declare `action-only:v1` so no periodic runner is
  scheduled for a config shape that cannot carry a token.
- NetBox SHALL declare a credential profile and take its API token from a
  credential rule, and its sources SHALL be configurable from the Settings UI
  rather than hand-written into assignment params.
- The VulnCheck environment-variable fallback SHALL be removed and the agent's
  file-based SNMP credential path SHALL be documented as the remaining exception
  with a migration path.
- `docs/docs/` SHALL gain a single credential-management guide covering secrets,
  rules, purposes, scopes, TLS policy, CA trust material, and the broker, with
  per-provider setup sections; the existing integration pages SHALL be corrected
  and made to use one consistent name and route for the page.

## Impact

- Affected specs: `wasm-plugin-system`, `credential-management`,
  `unifi-protect-camera-plugin`, `network-discovery`, `ansible-integration`,
  `netbox-inventory-plugin` (new).
- Affected code: `go/cmd/wasm-plugins/{unifi-protect,axis,proxmox,opentext-nom,awx,netbox}/`,
  `go/pkg/agent/plugin_runtime_http.go`,
  `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/network_credential_rules_live.ex`,
  `elixir/serviceradar_core/lib/serviceradar/credentials/`,
  `elixir/serviceradar_core/lib/serviceradar/inventory/proxmox_source_scope_resolver.ex`,
  `elixir/serviceradar_core/lib/serviceradar/inventory/advisory_feeds/config.ex`,
  `docs/docs/`.
- Security impact: adds a CA trust field to credential rules. Trust material is
  public, not secret, and is validated as PEM or as a hex fingerprint before use;
  it never widens the `verify` requirement it exists to satisfy. Declaring
  `allowed_networks` widens plugin egress to private address space by manifest
  declaration, which is signed and reviewed, rather than by wildcard.

## Related active changes

- `refactor-unified-credential-management` owns the long-term unified credential
  UX and the `credential-management` capability. This change fixes delivery
  defects underneath it and does not restructure the UI.
- `add-external-secret-provider-broker` owns broker grants and external providers.
  This change consumes that contract unchanged.
- `unify-plugin-credential-rules-db-surface` is superseded by this change: its
  five tasks describe UI gaps (`api_key` auth, camera purposes, controller-host
  metadata) that have since shipped, so implementing it as written would be work
  against a state that no longer exists.

## Non-Goals

- No CLI or JSON:API surface for credentials. The Credentials Ash domain remains
  UI-and-code-interface only.
- No change to broker grant issuance, TTL, or resolution-location semantics.
- No migration of remote-access or mapper credential stores.
