## Context
Agent self-update supports two artifact delivery modes:
- direct signed artifact URLs from release metadata
- gateway-authenticated artifact transport for managed rollouts

Today the downloader accepts any redirect that remains on HTTPS. That preserves transport confidentiality, but it does not preserve the authenticated or signed origin that selected the artifact.

## Decision
Release downloads will be origin-bound.

The agent will:
- capture the origin from the first request URL
- allow relative or absolute redirects only when the redirect target preserves:
  - `https` scheme
  - host
  - effective port
- reject any redirect that changes origin

This applies to both:
- direct artifact URLs from signed release metadata
- gateway-served artifact transport

## Rationale
This keeps the actual download inside the same trust boundary that authorized the initial request:
- signed direct URLs remain bound to the signed origin
- gateway-authenticated delivery remains bound to the gateway origin

Allowing cross-origin redirects would let the final artifact fetch leave that boundary even though the first request was authenticated or signed.

## Consequences
- repository-style release URLs that rely on cross-origin object-storage redirects will no longer be valid for agent self-update
- future release publishing/import flows must publish final artifact URLs or route delivery through a trusted same-origin endpoint such as the gateway
