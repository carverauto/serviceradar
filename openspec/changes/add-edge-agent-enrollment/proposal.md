# Change: Add edge agent enrollment and gateway reachability

## Why
serviceradar-agent currently lacks a CLI enrollment flow for edge onboarding packages, and the edge package UI is broken on /admin/edge-packages. This blocks the intended workflow where operators generate an onboarding package in web-ng and enroll an agent using a token. Deployments also do not consistently expose the agent-gateway endpoint to edge agents, so onboarding packages cannot include a reachable gateway address.

## What Changes
- Add serviceradar-agent enrollment flags to accept an edgepkg token, download the package, and write agent bootstrap config and certificates.
- Include agent identity (agent_id, partition), gateway endpoint, and host IP resolution in edge onboarding packages for agents, with UI prompts for optional host IP.
- Consolidate edge onboarding UI entry points so Settings → Agents → Deploy is the primary flow and remove redundant Edge Ops navigation.
- Move plugin management under Settings → Agents and remove the Edge Ops components tab.
- Remove legacy Go edge onboarding hooks from non-edge binaries to avoid dead code paths.
- Replace SaaS hardcoded base URLs/endpoints with deployment-local defaults and configuration.
- Allow operators to configure and expose an externally reachable agent-gateway endpoint in Docker Compose and Helm, and surface that endpoint in onboarding packages.

## Impact
- Affected specs: edge-onboarding, agent-connectivity, edge-architecture, docker-compose-stack.
- Affected code: cmd/agent, pkg/edgeonboarding, web-ng edge onboarding LiveViews/forms, core edge package delivery, docker compose manifests, Helm chart/service values.
