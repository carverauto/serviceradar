defmodule ServiceRadar.Edge do
  @moduledoc """
  The Edge domain manages edge onboarding packages, events, and NATS credentials.

  This domain is responsible for:
  - Edge onboarding package creation and delivery
  - Package lifecycle management (state machine)
  - Onboarding event tracking
  - Download token management
  - NATS credential issuance and lifecycle for collectors
  - Collector package management (flowgger, trapd, netflow, otel)
  - Edge site management (NATS leaf deployments)

  ## Resources

  - `ServiceRadar.Edge.OnboardingPackage` - Edge deployment packages
  - `ServiceRadar.Edge.OnboardingEvent` - Package lifecycle events
  - `ServiceRadar.Edge.NatsCredential` - NATS credentials for collectors
  - `ServiceRadar.Edge.CollectorPackage` - Collector-specific deployment packages
  - `ServiceRadar.Edge.EdgeSite` - Edge deployment locations
  - `ServiceRadar.Edge.NatsLeafServer` - NATS leaf server configurations
  - `ServiceRadar.Edge.AgentCommand` - On-demand agent command lifecycle records
  - `ServiceRadar.Edge.AgentRelease` - Published agent release catalog
  - `ServiceRadar.Edge.AgentReleaseRollout` - Desired-version rollout plans
  - `ServiceRadar.Edge.AgentReleaseTarget` - Per-agent rollout state
  - `ServiceRadar.Edge.RemoteAccessSession` - Generic remote-access session lifecycle
  - `ServiceRadar.Edge.RemoteAccessRequest` - Remote-access approval requests
  - `ServiceRadar.Edge.RemoteAccessRecording` - Remote-access recording manifests
  - `ServiceRadar.Edge.RemoteAccessRecordingEvent` - Remote-access replay events
  - `ServiceRadar.Edge.RemoteAccessFileTransfer` - Remote-access file-transfer metadata
  - `ServiceRadar.Edge.RemoteAccessHostKey` - Remote-access SSH host-key trust state
  - `ServiceRadar.Edge.RemoteAccessDesktopTarget` - Registered desktop/RDP target policy
  - `ServiceRadar.Edge.RemoteAccessApplicationTarget` - Registered HTTP/HTTPS application target policy
  - `ServiceRadar.Edge.RemoteAccessTcpTarget` - Registered raw TCP target policy
  - `ServiceRadar.Edge.ProxmoxConsoleSession` - Proxmox console session tickets and lifecycle

  ## Package State Machine

  Onboarding packages follow a defined lifecycle:
  - `created` -> `downloaded` -> `installed` -> `expired`
  - `created` -> `revoked` (manual action)

  State transitions are enforced by AshStateMachine and integrated
  with AshOban for expiration jobs.
  """

  use Ash.Domain,
    extensions: [
      # AshJsonApi.Domain,
      AshPaperTrail.Domain,
      AshAdmin.Domain
    ]

  paper_trail do
    include_versions? true
  end

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Edge.OnboardingPackage
    resource ServiceRadar.Edge.OnboardingEvent
    resource ServiceRadar.Edge.NatsCredential
    resource ServiceRadar.Edge.CollectorPackage
    resource ServiceRadar.Edge.EdgeSite
    resource ServiceRadar.Edge.NatsLeafServer
    resource ServiceRadar.Edge.AgentCommand
    resource ServiceRadar.Edge.AgentRelease
    resource ServiceRadar.Edge.AgentReleaseRollout
    resource ServiceRadar.Edge.AgentReleaseTarget
    resource ServiceRadar.Edge.RemoteAccessSession
    resource ServiceRadar.Edge.RemoteAccessRequest
    resource ServiceRadar.Edge.RemoteAccessRecording
    resource ServiceRadar.Edge.RemoteAccessRecordingEvent
    resource ServiceRadar.Edge.RemoteAccessFileTransfer
    resource ServiceRadar.Edge.RemoteAccessHostKey
    resource ServiceRadar.Edge.RemoteAccessDesktopTarget
    resource ServiceRadar.Edge.RemoteAccessApplicationTarget
    resource ServiceRadar.Edge.RemoteAccessTcpTarget
    resource ServiceRadar.Edge.ProxmoxConsoleSession
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
