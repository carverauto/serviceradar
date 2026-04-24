# Change: Harden Helm Generated Secret Defaults

## Why
The Helm chart still ships two fixed shared-secret defaults: a static onboarding signing key in `secrets.edgeOnboardingKey`, and a static Erlang cluster cookie in `webNg.clusterCookie`. Unless operators override them manually, distinct installs can reuse the same onboarding trust root and the same internal cluster credential.

## What Changes
- Stop shipping a fixed onboarding signing key in chart defaults.
- Generate a unique onboarding signing key per install when no explicit override is provided.
- Stop templating a static default cluster cookie into core, web-ng, and agent-gateway.
- Generate a unique cluster cookie per install when no explicit override is provided.
- Document the override and rotation behavior in the chart docs.

## Impact
- Affected specs: `edge-onboarding`, `ash-cluster`
- Affected code: `helm/serviceradar/values.yaml`, `helm/serviceradar/templates/secret-generator-job.yaml`, `helm/serviceradar/templates/core.yaml`, `helm/serviceradar/templates/web.yaml`, `helm/serviceradar/templates/agent-gateway.yaml`, `helm/serviceradar/README.md`
