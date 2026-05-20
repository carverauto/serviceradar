---
sidebar_position: 9
title: "Remote Access: RDP"
---

# Remote Access: RDP

ServiceRadar desktop/RDP access uses the same agent-routed remote-access plane as SSH, but it is a separate graphical workflow. RDP sessions are routed through a selected edge agent, use a dedicated desktop media path for screen updates, and keep target credentials out of browser storage and persisted session metadata.

:::caution Experimental — not generally available
RDP remote access is an experimental feature and is not yet generally available. It remains experimental until the reviewed IronRDP connector backend is linked and the helper readiness probe reports `connector_ready: true`. Base agent installs do not include the RDP helper. RDP-capable artifacts are optional and are hidden from EdgeOps unless the deployment explicitly enables desktop RDP.
:::

## Connection Path

```text
browser RDP renderer
  -> web-ng WebRTC signaling
  -> core-elx desktop media manager
  -> agent-gateway desktop media service
  -> selected edge agent
  -> per-session serviceradar-rdp-adapter helper
  -> registered Windows RDP target
```

Use the generic control path for lifecycle and low-rate controls such as open, close, keyboard, pointer, resize, focus, quality, and revocation. Use the dedicated desktop media stream for screen updates, cursor updates, frame metadata, heartbeat, close, and backpressure acknowledgements. Do not route production RDP screen traffic through terminal byte frames.

## Enablement Checklist

Before enabling RDP in an environment:

- Register only trusted RDP targets. Users must not be able to supply arbitrary upstream hosts or ports at session launch.
- Assign each target to the agent or allowed agent set that can reach TCP `3389` or the target-specific RDP port.
- Enable the web-ng/core feature flag only in deployments that should expose RDP UI and WebRTC signaling:

```bash
SERVICERADAR_REMOTE_ACCESS_DESKTOP_RDP_ENABLED=true
```

- Deploy an RDP-capable signed agent artifact only to the agents that should host desktop sessions. Standard base agents should remain the default for the rest of the fleet.
- Verify the helper locally on the agent host:

```bash
serviceradar-rdp-adapter --capabilities
```

The helper must report schema `serviceradar.rdp.helper.capabilities.v1`, protocol `rdp`, `ironrdp_backend_linked: true`, and `connector_ready: true` before the agent may advertise `remote_access.rdp`. While `connector_ready` is `false`, the helper also reports `connector_ready_reason` so operators can distinguish an unlinked backend from an IronRDP-linked helper that still lacks live authentication, media, cleanup, and demo proof.

## Target Policy

An RDP target policy is compiled by the control plane and sent to the selected agent as a trusted per-session snapshot. The browser never chooses the upstream address, credential secret, route, TLS policy, or redirection policy.

Example policy shape:

```json
{
  "target_id": "win-admin-01-rdp",
  "display_name": "win-admin-01",
  "device_uid": "device-win-admin-01",
  "protocol": "rdp",
  "route": {
    "selected_agent_id": "agent-edge-01",
    "selected_gateway_id": "gateway-default",
    "allowed_agent_ids": ["agent-edge-01"]
  },
  "upstream": {
    "host": "10.0.0.10",
    "port": 3389
  },
  "tls": {
    "mode": "verify",
    "ca_bundle_id": "corp-rdp-ca",
    "ca_bundle_pem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
    "nla_mode": "required",
    "server_name": "win-admin-01.example.com"
  },
  "credential": {
    "mode": "memory_user",
    "allowed_principals": ["EXAMPLE\\\\alice", "alice@example.com"]
  },
  "screen": {
    "max_width": 1920,
    "max_height": 1080,
    "frame_rate": 30,
    "bitrate_bps": 8000000,
    "idle_seconds": 900,
    "ttl_seconds": 3600
  },
  "redirection": {
    "clipboard_mode": "disabled",
    "drive": false,
    "printer": false,
    "audio": false,
    "smart_card": false,
    "file_copy": false
  },
  "approval_required": false,
  "recording": {
    "metadata_enabled": true,
    "screen_enabled": false,
    "clipboard_enabled": false,
    "file_enabled": false,
    "audio_enabled": false
  },
  "metadata": {
    "rdp.dial_timeout_ms": "10000",
    "rdp.kdc_timeout_ms": "10000"
  }
}
```

`rdp.dial_timeout_ms` and `rdp.kdc_timeout_ms` are optional trusted target
metadata overrides for the helper's TCP dial stage and Kerberos/KDC stage. Keep
them unset unless an environment needs a longer stage timeout; the helper caps
each value at 30 seconds.

Secure defaults:

- `protocol` defaults to `rdp`.
- RDP port defaults to `3389`.
- TLS mode defaults to `verify`.
- NLA mode defaults to `required`.
- Screen recording and clipboard recording are disabled unless explicitly enabled.
- Metadata recording is enabled when no recording fields are set.
- Clipboard mode defaults to `disabled`.

## RBAC And Approval

Grant RDP access separately from SSH:

- Use `devices.remote_access.rdp.open` for graphical desktop access.
- Continue using `devices.remote_access.ssh.open` for SSH.
- Keep `devices.console.open` scoped to console entry points such as Proxmox host shells.

Brokered reusable credentials require approval. This is intentional: brokered credentials are a compatibility escape hatch and must be bound to actor, session, target, route, TTL, and audit metadata before release. Do not use a shared desktop administrator credential as the normal enterprise path.

## Credential Modes

Preferred modes:

- `domain_delegation`: the target sees the real enterprise identity through domain-backed delegation when the environment supports it.
- `smart_card`: future smart-card or certificate-backed user authentication. Treat this as a separate credential-custody review before broad use.
- `memory_user`: the user supplies their own domain credential for one session. The credential is delivered only to the selected agent/helper and dropped on close, timeout, route loss, auth failure, or adapter startup failure.

Fallback mode:

- `brokered_secret`: a centrally brokered, target-bound credential. This must require approval, TTL, and target/session/route binding. The agent must receive only the session grant and must not persist reusable secrets locally.

Never store RDP passwords, generated RDP files, smart-card material, or credential caches on agents or in browser storage.

## TLS And NLA

Use NLA-required RDP as the default posture — see the `tls` block in the
[Target Policy](#target-policy) example above.

TLS modes:

- `verify`: verify the target certificate using the configured trust roots and server name.
- `pinned_ca`: verify using a named CA bundle managed by ServiceRadar policy.
- `system`: use the agent host system trust store.
- `tofu`: trust-on-first-use for controlled enrollment only.
- `insecure`: lab-only. Do not use in production.

`server_name` is the TLS certificate identity, not necessarily the dial address.
It must be an ASCII DNS name using LDH labels (`A-Z`, `a-z`, `0-9`, hyphen, and
dots). IP literals are rejected for verified TLS. You may dial an RDP target by
private IP in `upstream.host`, but the target certificate must still contain a
matching DNS SAN and `server_name` must use that DNS name.

For production RDP, prefer `verify` with an explicit ServiceRadar-managed CA bundle
or `pinned_ca` for private Windows/xrdp certificates. The helper path is expected
to build a normal Rustls client verifier from PEM CA bundle material, reject DER,
empty, or malformed bundles, and disable TLS resumption because CredSSP does not
support it. `system` loads the selected agent host's native trust store and must
fail closed if the store cannot be loaded or contains no usable roots. Do not use
TOFU as a standing trust model; it implies persistent agent-local state and should
stay limited to a reviewed enrollment workflow.

Registered CA bundles are public trust material, not credentials. For registered
bundle modes, the trusted session policy should include both `ca_bundle_id` for
auditability and bounded `ca_bundle_pem` material so the selected helper can
verify the target without agent-local trust state. Do not put private keys or
passwords in target TLS policy.

Keep `nla_mode` set to `required` for Windows RDP. Disabling NLA is a temporary lab-only setting and should not pass production policy review.

## Redirection Controls

All redirection features are disabled by default — see the `redirection` block
in the [Target Policy](#target-policy) example above.

Clipboard modes:

- `disabled`: no clipboard traffic.
- `text_to_remote`: browser-to-target text only.
- `text_to_browser`: target-to-browser text only.
- `text_bidirectional`: text both ways.

Drive, printer, audio, smart-card, and file-copy redirection should remain disabled until each feature has its own policy, audit, malware scanning or export-control posture, and tests. Use ServiceRadar file-transfer workflows for controlled file movement rather than enabling drive redirection by default.

## Recording And Audit

Metadata recording is the default. It records session facts, not desktop content:

- actor, session, route, selected agent, target, protocol, and credential mode
- TLS/NLA posture and policy decisions
- screen resolution, frame rate, bitrate, byte counters, duration, and close reason
- redirection state and policy decisions
- approval reviewer metadata when approval is required

Screen frames, screenshots, clipboard content, file contents, audio, and smart-card events are sensitive content. Enable content recording only when an explicit policy, retention period, user-visible session indicator, and export access model are in place.

Example metadata-only recording policy:

```json
{
  "recording": {
    "metadata_enabled": true,
    "screen_enabled": false,
    "clipboard_enabled": false,
    "file_enabled": false,
    "audio_enabled": false
  }
}
```

## Optional Agent Distribution

The base agent remains the default fleet artifact. RDP-capable releases are optional:

- The signed release manifest for the base artifact should declare `capabilities: ["agent"]`.
- RDP-capable bundles should declare `remote_access.rdp` and include helper metadata, helper protocol version, compatibility range, checksums, signatures, SBOM/license review references, and deployment requirements. Experimental bundles with `helper_connector_ready: false` must also include `helper_connector_ready_reason`.
- EdgeOps hides artifacts with `remote_access.rdp` unless `SERVICERADAR_REMOTE_ACCESS_DESKTOP_RDP_ENABLED=true`.
- One-click rollout installs the RDP helper only when the selected signed artifact declares `remote_access.rdp`.
- Installed agents must not advertise `remote_access.rdp` until the helper readiness probe passes.

For release artifact details, see [Agent Release Management](./agent-release-management).

## Operator Workflow

1. Enable RDP only in a controlled deployment.
2. Publish or import a signed RDP-capable agent artifact.
3. Use EdgeOps to deploy the RDP-capable artifact to the selected edge agent cohort.
4. Verify the helper readiness probe on those agents.
5. Register RDP targets with fixed upstream host/port, allowed agent set, TLS/NLA policy, credential mode, screen policy, redirection policy, and recording policy.
6. Grant `devices.remote_access.rdp.open` only to the intended roles.
7. Start with metadata-only recording and all redirection disabled.
8. Validate one private target before expanding the target set.

## Validating A New Deployment

When bringing up RDP in a new environment, validate against a private target
that is reachable from the selected edge agent but not reachable directly from
web-ng or the operator browser. A Windows host with NLA enabled is the
production-representative path. Register the target as described in the
[Operator Workflow](#operator-workflow) (step 5), starting with a conservative
screen policy such as `1280x720` at 15 fps and raising limits only after
backpressure counters stay healthy.

Validation checklist:

- A user without `devices.remote_access.rdp.open` cannot list or open the target.
- A user with `devices.remote_access.rdp.open` can list only authorized RDP targets.
- Browser session metadata shows the target, route, credential mode, TLS/NLA posture, recording mode, and redirection state without any credential material.
- The agent advertises `remote_access.rdp` only after local config enables RDP and the helper readiness probe passes.
- Desktop media counters advance only on the dedicated desktop media stream.
- Browser backpressure updates return credit through the WebRTC control DataChannel and the agent slows or pauses when credit is exhausted.
- Closing the browser session closes the helper process and clears the memory-user credential grant.
- Recording/audit views show lifecycle and policy metadata without screen frames or clipboard payloads.

## Troubleshooting

- RDP action hidden: verify `SERVICERADAR_REMOTE_ACCESS_DESKTOP_RDP_ENABLED=true` in web-ng/core.
- Agent does not advertise `remote_access.rdp`: verify the selected artifact includes the helper, the agent config enables RDP, the helper path is executable, and `serviceradar-rdp-adapter --capabilities` reports `connector_ready: true`.
- Route denied: the target policy selected agent is missing, not in `allowed_agent_ids`, or not the local agent receiving the open frame.
- Target connection refused or timed out: the selected edge agent cannot reach the target upstream host and port.
- TLS verification failed: fix `server_name`, trust roots, or the target certificate. Do not switch to `insecure` outside a lab.
- NLA failure: confirm the Windows host requires NLA and that the credential mode supplies a valid domain/local user for that target.
- Clipboard denied: confirm the target redirection policy enables the requested clipboard direction.
- Session closes under load: inspect desktop media backpressure and quota logs for exhausted credit windows, bitrate caps, frame-rate caps, max-chunk rejection, or browser pause/close acknowledgements.
