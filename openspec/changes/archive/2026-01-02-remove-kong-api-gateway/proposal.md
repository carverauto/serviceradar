# Change: Remove Kong API Gateway

## Why
Kong is no longer used in any supported ServiceRadar deployment. Keeping it in default manifests and documentation adds maintenance overhead and causes confusion during local and demo setups.

## What Changes
- **BREAKING** Remove Kong from Docker Compose, Helm, and K8s demo/staging/prod manifests.
- Route UI/API traffic directly to web-ng and SRQL services without Kong.
- Remove Kong-specific packaging, config templates, and docs references.
- Update runbooks and architecture docs to describe the new edge routing model.

## Impact
- Affected specs: edge-routing (new), plus any docs that currently describe Kong as the API gateway.
- Affected code: Docker Compose manifests, Helm templates, K8s demo configs, packaging artifacts, and documentation.
