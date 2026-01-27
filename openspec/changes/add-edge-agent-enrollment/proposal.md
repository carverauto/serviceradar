# Change: Add edge agent enrollment and gateway reachability

## Why
Edge onboarding needs a single, stable enrollment command for operators. Having per-binary enrollment flows (agent + collectors) creates duplicated logic and dead code. The edge package UI is also broken on /admin/edge-packages, blocking the intended workflow where operators generate onboarding packages in web-ng and enroll using a token. Deployments also do not consistently expose the agent-gateway endpoint to edge agents, so onboarding packages cannot include a reachable gateway address.

## What Changes
- Add `serviceradar-cli enroll --token <token>` as the single enrollment entry point for agents and collectors.
- Move enrollment logic into shared `/pkg` helpers used by the CLI and remove per-binary `--enroll` flags from agents/collectors.
- Include agent identity (agent_id, partition), gateway endpoint, and host IP resolution in edge onboarding packages for agents, with UI prompts for optional host IP.
- Issue agent mTLS certificates from the agent-gateway and return the bundle to web-ng during package creation.
- Consolidate edge onboarding UI entry points so Settings → Agents → Deploy is the primary flow and remove redundant Edge Ops navigation.
- Move plugin management under Settings → Agents and remove the Edge Ops components tab.
- Replace SaaS hardcoded base URLs/endpoints with deployment-local defaults and configuration.
- Allow operators to configure and expose an externally reachable agent-gateway endpoint in Docker Compose and Helm, and surface that endpoint in onboarding packages.

## Impact
- Affected specs: edge-onboarding, agent-connectivity, edge-architecture, docker-compose-stack.
- Affected code: cmd/cli, pkg/edgeonboarding, cmd/agent, collector binaries, web-ng edge onboarding LiveViews/forms, core edge package delivery, docker compose manifests, Helm chart/service values.
