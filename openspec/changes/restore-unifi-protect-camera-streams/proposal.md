# Restore UniFi Protect Camera Streams

## Why

UniFi Protect streaming requires the inventory plugin, credential selection,
agent relay, and viewer transport to agree on a usable camera source. The agent
uses its native RTSP client by default; the stream plugin is selected only when
the relay-open command includes a stream plugin identifier.

The inventory integration must provide a reachable RTSPS source URL and an
agent/gateway assignment. The source must be enabled and relay-eligible, the
agent must be able to reach the controller, and a supported viewer transport
must be enabled. The credential settings UI must support API-key authentication
and an explicit controller host for these integrations.

## What Changes

- Ship the inventory plugin's static-controller-host support and enable the
  appropriate inventory assignment.
- Manage the integration API key as encrypted material in
  `platform.network_credential_secrets` through the canonical credential settings
  area. Bind camera-inventory and camera-stream purposes through credential rules.
  Keep credential values and deployment-specific connection details out of
  source-controlled proposals and examples.
- Configure controller metadata and a target query that resolves a device owned
  by the streaming agent through the deployment's credential-management workflow.
- Confirm inventory populates the RTSPS source URL, agent/gateway assignment, and
  relay eligibility. Enable WebRTC or the WebCodecs fallback as appropriate.
- Verify that an authorized viewer can render a camera stream end to end.

## Impact

- Affected specs: `unifi-protect`.
- Affected code: `go/cmd/wasm-plugins/unifi-protect/`, camera relay
  (`camera_relay*.go`, `relay_session_manager.ex`, `camera_multiview.ex`),
  and credential materialization (`unifi_protect_profile.ex`).
- Depends on `unify-plugin-credential-rules-db-surface` for API-key and camera authentication support
  in the credential settings UI.
