# AlienVault OTX credentials and scheduling

OTX package 0.3.4 declares its credential integration. After importing and
approving the signed package, create an **AlienVault OTX / API token** credential
in `/settings/networks/credentials`, then an agent-scoped rule with purpose
`threat_intel_sync`. Select one agent that can reach `otx.alienvault.com:443`.
The default bounded inventory query is a delivery gate; it does not filter the
global feed. One rule creates one assignment, rather than one pull per device.

Set the rule metadata to `interval_seconds: 86400` and `timeout_seconds: 600`.
Completed walks also self-throttle for one day. The assignment carries a
credential reference and an agent-bound broker grant. The existing config
delivery path resolves the token into the runtime `api_key` field; the token
stays encrypted in the unified CNPG credential inventory. Do not put the key in
Helm values, environment variables, job arguments, or plugin assignment params.

The legacy Threat Intel settings API key belongs to the **core worker** path.
Selecting `edge_plugin` does not inject that key into an edge assignment, and
enabling OTX without an assignment does not start collection. For an upgrade,
move the existing token through the credential API without displaying it or
writing it to a file. Keep the old encrypted value until the replacement
assignment has successfully imported a page, then remove the legacy value.
Keep one execution path active to avoid duplicate feed walks.

Verify collection using the OTX sync status's last attempt, last success,
imported/skipped counts, and cursor. Check that an imported indicator was updated
after the restored assignment ran. A healthy self-throttle response alone does
not prove that a new page was imported. Preserve the last-known-good indicators
when a fetch fails; their age and the feed's stale status should remain visible.
