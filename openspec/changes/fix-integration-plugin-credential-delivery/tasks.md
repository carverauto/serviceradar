# Tasks

## 1. Wasm sandbox egress (PR: fix/plugin-egress-literal-ip)
- [ ] 1.1 Add `allowed_networks` (RFC1918 + CGNAT, excluding link-local) to `unifi-protect`, `axis`, and `opentext-nom` manifests, including their `.stream` variants.
- [ ] 1.2 Confirm `proxmox` reaches its destination through the host-authority binding and add `allowed_networks` only if a gate actually denies it.
- [ ] 1.3 Add `action-only:v1` to the `awx` manifest so no periodic runner is scheduled for the command bridge.
- [ ] 1.4 Bump each edited plugin's manifest `version` and satisfy `scripts/check-native-addon-version-bumps.sh` where the plugin is a registered add-on.
- [ ] 1.5 Add a regression test asserting that a manifest with `allowed_domains: ["*"]` and no `allowed_networks` denies a literal private IP, and that the shipped manifests permit theirs.
- [ ] 1.6 Log egress denials with destination and failing gate; map `-2` to a named reason in the Go SDK error string.
- [ ] 1.7 Append `details.CollectionError` to the plugin summary on CRITICAL for `unifi-protect` (and `axis`, `opentext` where the same shape applies).

## 2. Credential rule TLS policy control (PR: fix/credential-rule-tls-policy-control)
- [ ] 2.1 Make the render-site `tls_policies` default match the validate-site default so the control renders whenever `rule_controls.transport` is true.
- [ ] 2.2 Add a LiveView regression test that saving a `unifi-protect` rule succeeds and that `skip_verify` round-trips.
- [ ] 2.3 Add the same coverage for `axis`.
- [ ] 2.4 Verify the hidden `producer_schedule` path still forces `verify` and is unaffected.

## 3. CA trust material (PR: fix/netbox-proxmox-credential-delivery)
- [x] 3.1 Add `ca_bundle_pem` and `server_cert_fingerprint` attributes to `NetworkCredentialRule` with a migration in the `platform` schema.
- [x] 3.2 Validate both at the changeset: PEM parses and is unexpired; fingerprint matches `^sha256:[0-9a-f]{64}$`; the two are mutually exclusive.
- [x] 3.3 Surface both fields in the credential rule form, shown when the provider declares transport controls.
- [x] 3.4 Carry trust material through the parameter template into plugin config and honour it in the agent HTTP client as the sole trust anchor.
- [x] 3.5 Keep `verify` mandatory for Proxmox `inventory_enrichment`; add a test proving a rule with a valid bundle passes and one without still fails closed.

## 4. NetBox credential surface (PR: fix/netbox-proxmox-credential-delivery)
- [x] 4.1 Add an `integrations.credential_profiles` entry for `netbox` with `api_token` auth and an `inventory_sync` purpose.
- [x] 4.2 Move the per-source `api_token` out of assignment params to a credential rule reference; keep non-secret source fields as params.
- [ ] 4.3 Add a Settings surface for NetBox sources so `sources[]` is no longer hand-written.
- [x] 4.4 Fail the check with a message naming the missing piece rather than the generic `has no sources configured`.

## 5. Remaining environment-sourced credentials (PR: fix/netbox-proxmox-credential-delivery)
- [x] 5.1 Remove the `VULNCHECK_API_TOKEN` / `SERVICERADAR_VULNCHECK_TOKEN` fallback from `advisory_feeds/config.ex`; require a `credential_ref`.
- [x] 5.2 Add a migration note and a startup warning for any feed row still lacking a `credential_ref`.
- [ ] 5.3 Document the agent `/etc/serviceradar/snmp.json` path as the one remaining file-based credential source, with its migration path to broker-backed SNMP references.

## 6. Documentation (PR: docs/credential-management-guide)
- [ ] 6.1 Add `docs/docs/credentials.md`: secrets vs rules, purposes, scope types, priority, runtime (Auto vs SRQL), TLS policy, CA trust material, and how a rule reaches a plugin through the broker.
- [ ] 6.2 Add per-provider setup sections: Proxmox (including obtaining and pinning the node CA), UniFi Protect, Axis, AWX/AAP, NetBox, VulnCheck, SNMP.
- [ ] 6.3 Correct `netbox.md` (token no longer in assignment params), `unifi-protect.md` (TLS policy now renders; controller reachability requires `allowed_networks`), and `ansible.md` (AWX is `credential_only`, not a rule).
- [ ] 6.4 Normalise the page name and route across all pages to "Settings -> Networks -> Credential Rules" at `/settings/networks/credentials`.
- [ ] 6.5 Add a troubleshooting section mapping each observed symptom to its cause: `0 cameras, 0 streams`, `Invalid TLS policy`, `api_token is required`, `has no sources configured`, `proxmox_tls_verification_required`.
- [ ] 6.6 Add the new page to the docs sidebar.

## 7. Supersede the stale change
- [x] 7.1 Archive `unify-plugin-credential-rules-db-surface` as superseded by this change.

## 8. Verification
- [ ] 8.1 `make test` green.
- [ ] 8.2 Publish, register, and re-materialise the rebuilt plugin packages in `demo`.
- [ ] 8.3 Confirm a **fresh** `service_status` row (timestamp after the rollout completes) for UniFi Protect, Proxmox Inventory, AWX Bridge, and NetBox, each reporting OK — not merely that the deploy succeeded.
- [ ] 8.4 Confirm a `proxmox` broker grant is minted, which has never happened in the demo deployment.
