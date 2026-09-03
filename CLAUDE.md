Always read @AGENTS.md

# Never commit data captured from a live system

This overrides convenience, and it applies to every fixture, example, README
sample, doc snippet, seed file, decoder test and debugging artifact you write.

**Fixtures are invented, never exported.** If you are reproducing a bug with data
from a running deployment — production, staging, lab, demo, customer or partner —
that data does not enter the repository. Construct an equivalent synthetic case.

Forbidden when real; use the reserved alternative:

| Class | Use instead |
| --- | --- |
| Hostnames, FQDNs, device/site/closet naming schemes | `host01.example.com`, `SITE01-...` |
| Site, region, facility or datacenter codes | invented codes |
| IPs and CIDRs, including someone else's RFC1918 plan | `192.0.2.0/24`, `198.51.100.0/24` |
| MACs with a real vendor OUI | `00:00:5e:00:53:xx` |
| Serial numbers, asset tags, chassis IDs | invented |
| Exact firmware/build numbers tied to a deployment | generic version |
| GPS coordinates resolving to a real facility | `0.0, 0.0` |
| Phone numbers, including NOC lines | `555-0100`–`555-0199` |
| Person names, emails, usernames, employee IDs | invented |
| Namespaces, cluster/tenant/workspace/account names | invented |
| Policy, AAA/802.1X, RADIUS, VLAN, SSID names | invented |
| Session IDs, syslog/packet captures, trace IDs | hand-constructed |
| Fleet scale figures describing a real estate | rounded, invented |

**Removing the organization's name is not enough.** A naming convention, a
coordinate pair, a build number, a serial, or a distinctive fleet shape
identifies an organization on its own. If data turns out to be real,
**regenerate the fixture** — do not search-and-replace it, because replacement
keeps the shape and the shape is the tell.

Four things that make this worse than it looks:

- **Non-test source ships.** Decoder tests, `README.md` samples and docs-site
  pages are published product.
- **Downstream registries are immutable.** crates.io, `proxy.golang.org` /
  `sum.golang.org`, npm, hex.pm, OCI registries and the docs site **cannot be
  fixed by rewriting git history**. Check before you publish.
- **Commit identity is content.** Author/committer email cannot be corrected
  without rewriting history. Verify `git config user.email` in every clone and
  worktree; a global identity survives a re-clone.
- **Do not name the affected party** in a commit message, branch name or PR
  title — including when removing their data. Describe the change by class.

**Anchor every search pattern.** An organization abbreviation is usually a
substring of ordinary English; here an unanchored three-letter match returned
~20,000 lines against ~480 real ones (`equal`, `manual`, `actual`, `virtual`,
`toEqual`, `quality`). Fed to a history-rewriting tool, that corrupts every
commit at once, unreviewably. Prove a pattern does not over-match before running
it.

If you find captured data already committed, map how far it spread — other
fixtures, published packages, the docs site, release tags — before deleting
anything. The deletion is the easy half.
