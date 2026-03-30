## Context
The chart currently treats two security-sensitive values like ordinary defaults:
- `secrets.edgeOnboardingKey` is set to a literal base64 value in `values.yaml`
- `webNg.clusterCookie` defaults to `serviceradar_dev_cookie`

The secret-generator hook already knows how to generate random secret material. The problem is that the chart feeds fixed values into that path, so installs can converge on shared credentials unless the operator notices and overrides them.

## Goals
- Ensure each install gets a unique onboarding signing key by default.
- Ensure each install gets a unique cluster cookie by default.
- Preserve explicit operator overrides where they are intentionally provided.

## Non-Goals
- Changing the onboarding token format or cluster cookie mechanism.
- Rotating existing installed secrets automatically.

## Decisions
### Generate when unset
The chart should treat both values as generated secret material, not static defaults. If the operator supplies an explicit override, the chart may use it. Otherwise the pre-install/pre-upgrade secret generation path should mint a fresh value.

### Keep generation in the existing secret hook
The existing secret-generator job already owns other install-scoped secrets. Extending that path keeps behavior centralized and avoids adding new secret-generation mechanisms elsewhere in the chart.

## Verification
- Helm template/tests or focused linting confirm no fixed onboarding key or cluster cookie remains in chart defaults.
- OpenSpec validation and diff checks remain clean.
