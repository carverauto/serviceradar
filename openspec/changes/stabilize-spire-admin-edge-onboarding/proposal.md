# Change: Stabilize SPIRE admin for edge onboarding

## Why
- Edge checker onboarding fails with 502 because Core cannot reach SPIRE admin (`x509: certificate signed by unknown authority`) while creating join tokens.
- SPIRE server PSAT allow-list does not include Core/Datasvc service accounts, so the admin mTLS handshake breaks and Core crashloops.

## What Changes
- Update the Helm SPIRE server config to trust Core and Datasvc service accounts for k8s_psat attestation.
- Roll out SPIRE (server/agents) and restart Core/Web so the new trust settings take effect.
- Validate edge onboarding create-package flows after SPIRE trust is fixed.

## Impact
- Affected specs: none (bugfix to existing SPIRE trust behavior).
- Affected code: Helm SPIRE server template, demo rollout procedure, edge onboarding create package path (Core/SPIRE admin).
