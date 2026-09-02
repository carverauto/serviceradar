# Design

## Context

Five independent defects sit between a correctly stored credential and a working
plugin. They share one property worth naming up front: **each reports as
something other than what it is.** A sandbox egress denial reports as "0 cameras".
A form field that was never rendered reports as "Invalid TLS policy". A
fail-closed TLS check reports as a downstream ingest failure. Fixing the delivery
paths without fixing the reporting would leave the next operator in the same
position, so error legibility is part of the change, not a nicety.

## Decision 1: CA trust material on the credential rule

### The problem

`ProxmoxSourceScopeResolver.validate_rule_transport/2` requires exactly
`{"proxmox_api_token", "verify"}` for `inventory_enrichment`. Proxmox VE ships a
self-signed certificate issued for the node hostname. The agent additionally
requires an `https` origin whose host is a bare IP literal. A certificate issued
for `pve04.lan` can never validate against `https://192.168.1.20`, so today the
requirement is unsatisfiable in the environment it was written for, and the only
way to make Proxmox work is to weaken the check.

### Options considered

| Option | Verdict |
|---|---|
| Allow `skip_verify` for `inventory_enrichment` | Rejected. Deletes a fail-closed check someone wrote deliberately, and Proxmox enrichment writes to device identity — a MITM there is an identity-forgery primitive, not just bad metrics. |
| Trust the PVE CA out-of-band on each agent host | Rejected as the primary path. No code change, but it is per-host manual setup with no record in ServiceRadar, invisible at review time, and silently lost when an agent host is rebuilt. |
| **Operator-supplied CA trust material on the rule** | **Chosen.** |

### Shape

Two new optional, mutually exclusive fields on `NetworkCredentialRule`:

- `ca_bundle_pem` — a PEM chain used as the sole trust anchor for this rule's
  destinations.
- `server_cert_fingerprint` — a `sha256:<64 hex>` pin, for operators who prefer
  pinning a leaf over managing a chain.

Both are **public, not secret**. They are trust anchors, not authenticators:
publishing a CA certificate reveals nothing, and treating them as secrets would
force them through the broker for no benefit while making them invisible in the
UI where an operator needs to read them back. They are therefore plain columns on
the rule, not `NetworkCredentialSecret` records.

`verify` stays mandatory for Proxmox `inventory_enrichment`. What changes is that
it becomes *satisfiable*: the rule now carries the trust material that makes
verification succeed against a private CA.

### Verification semantics

Trust material narrows rather than widens. When either field is set the
destination is validated against **that anchor alone**, not against it *plus* the
system store — otherwise a rule pinning a private CA would still accept any
publicly-trusted certificate, which is a weaker posture than the operator asked
for. Hostname verification still applies with a bundle; a fingerprint pin matches
the leaf exactly and so subsumes it.

Validation at write time: `ca_bundle_pem` must parse as one or more
certificates and must not have expired; `server_cert_fingerprint` must match
`^sha256:[0-9a-f]{64}$`. Both reject at the changeset, not at first use — a
credential rule that fails only when a plugin runs three hours later is exactly
the reporting failure this change exists to remove.

## Decision 2: egress permissions stay declarative

The temptation is to make `allowed_domains: ["*"]` also cover IP literals. That
would fix all four plugins in one line and is wrong: the comment at
`plugin_runtime_assignment.go:497` says *"never let a domain wildcard expand into
an arbitrary IP/network permission"*, and it is right. A wildcard is a statement
about DNS names an operator cannot fully enumerate; private address space is a
different and much more sensitive reachability claim — it is where the
unauthenticated internal estate lives.

So each manifest declares the address space it needs, the way NetBox already
does. This keeps the claim reviewable in a signed artifact. The cost is that a
plugin reaching an appliance outside RFC1918 needs a manifest edit; that is the
intended friction.

`allowed_networks` for the four affected plugins is RFC1918 plus CGNAT
(`100.64.0.0/10`), which covers Tailscale and carrier-NAT lab setups, and
link-local (`169.254.0.0/16`) is deliberately **excluded** — no controller is
legitimately reached there, and it is where APIPA phantoms live.

## Decision 3: make denials legible

Three reporting fixes, each a precondition for the operator ever debugging this
themselves:

1. The agent logs an egress denial with the destination and the failing gate
   (host vs port). It currently logs the denial without saying which rule denied
   it.
2. The UniFi plugin appends `details.CollectionError` to its summary when the
   status is CRITICAL, so the operator sees `UniFi Protect: 0 cameras, 0 streams
   (host error -2 (http_request))` rather than a bare count. The pattern
   generalises to Axis and OpenText.
3. The SDK maps `-2` to a named string. `host error -2` is unsearchable;
   `permission denied by plugin egress policy` is not.

## Decision 4: NetBox sources move to the DB

NetBox's `sources[]` array currently lives in `plugin_assignments.params` with a
plaintext `api_token` per source. The token moves to a `netbox` credential
profile with `api_token` auth; the non-secret parts of a source (base URL, tag
filters, site filter) stay assignment params, referencing the rule by id. This
mirrors what AWX already does with `credential_broker` + `api_token_secret_ref`
and needs no new mechanism.

## Risks

- **A stale registered manifest keeps the old permissions.** Plugin packages are
  versioned rows; the agent uses whatever version the assignment points at.
  Bumping the manifest is not enough — the new package must be registered and the
  assignment moved to it. The rollout step is therefore "publish, register,
  re-materialise", and the verification is a fresh `service_status` row, not a
  successful build.
- **`allowed_networks` widens egress.** Mitigated by manifest signing and by
  excluding link-local. A plugin that is compromised can now reach private space
  it could not before; it could already do so by hostname, so this closes a gap
  in consistency rather than opening a new class.
- **CA bundles expire.** A rule whose pinned chain expires fails closed with a
  TLS error. Write-time expiry validation catches the obvious case; a rotting
  bundle is surfaced by the same rule-test path as any other credential problem.
