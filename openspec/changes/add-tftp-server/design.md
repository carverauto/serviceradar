## Context

Network operators managing switches, routers, and access points need two complementary capabilities:

1. **Receive**: Pull configuration backups or diagnostic dumps off devices via TFTP (device initiates PUT to agent)
2. **Serve**: Push firmware images to devices for upgrades or zero-touch provisioning (device initiates GET from agent)

Both require a managed TFTP server on the agent, but they have different workflows. Receiving is ad-hoc (operator triggers a backup). Serving requires pre-staging a firmware image from a centralized software library onto the edge agent before a device can download it.

TFTP (RFC 1350) is inherently insecure (no auth, no encryption), so all security comes from our lifecycle controls: ephemeral servers, filename allowlisting, and the authenticated command bus.

Beyond TFTP, operators need a **software library** — a centralized place to upload, version, verify, and distribute firmware images. This library feeds into TFTP serve sessions and could later support other distribution methods (SCP, HTTP).

### Stakeholders
- Network operators (primary users — firmware management, config backup, ZTP)
- Security team (TFTP insecurity, S3 credential management, firmware integrity)
- Platform team (new agent capability, new Ash domain, S3 integration)

### Constraints
- TFTP protocol has no authentication — security comes from lifecycle controls
- Agents may be on restricted networks; S3 access must be orchestrated by core-elx
- File sizes can be large (firmware images up to ~100MB); must handle streaming
- TFTP uses UDP port 69 by default; agent may need elevated privileges or a high port
- S3 credentials must be handled securely — either never stored in DB (ENV mode) or encrypted at rest (AshCloak mode)

## Goals / Non-Goals

### Goals
- On-demand TFTP server with full lifecycle management via command bus (both receive and serve modes)
- Software library for uploading, versioning, and managing firmware images
- Image staging: push firmware from library to edge agents for TFTP serving
- Zero-touch provisioning: serve firmware images to devices via TFTP GET
- Dual S3 credential modes: ENV-based (secure-by-default) or AshCloak-encrypted in DB
- Real-time transfer monitoring in the Settings UI
- Strong security controls (allowlisted filenames, timeouts, size limits, checksums, signatures, audit trail)
- Automatic server shutdown after transfer completion or timeout

### Non-Goals
- TFTP server as a persistent/always-on service (explicitly not supported)
- SCP/SFTP support — different protocol, different proposal
- Direct agent-to-S3 upload (agent may not have internet/S3 access)
- Full PKI / code signing infrastructure (we store and verify signatures, but don't run a CA for firmware signing)
- Firmware auto-detection (operator must know which image goes to which device)

## Decisions

### Decision 1: TFTP Library Selection (Go)
**Choice**: Use `pin/tftp` (github.com/pin/tftp) — mature, well-tested Go TFTP library
**Alternatives considered**:
- Raw UDP implementation — too much work, RFC compliance burden
- `go-tftp` — less maintained than `pin/tftp`
**Rationale**: `pin/tftp` supports both read and write handlers (needed for serve + receive modes), timeouts, and is actively maintained. Custom handlers enforce filename allowlisting and size limits.

### Decision 2: File Transfer Between Agent and Core
**Choice**: gRPC streaming through the existing agent→gateway connection (bidirectional)

The agent does NOT have access to NATS JetStream — it only communicates with the agent-gateway via gRPC with mTLS. File transfer must use this existing gRPC path.

**New RPCs added to `AgentGatewayService`**:
```protobuf
// Agent uploads a file to the gateway (receive mode: TFTP backup → core storage)
rpc UploadFile(stream FileChunk) returns (FileUploadResponse);

// Agent downloads a file from the gateway (serve mode: library image → agent staging)
rpc DownloadFile(FileDownloadRequest) returns (stream FileChunk);
```

**Data flow**:
- **Receive** (device → agent → gateway → core): Agent receives file via TFTP, then streams it to the gateway via `UploadFile` gRPC. The gateway forwards to core-elx via Erlang RPC or writes to NATS JetStream (gateway has NATS access). Core persists to local/S3 storage.
- **Serve** (core → gateway → agent → device): Agent calls `DownloadFile` to pull the firmware image from the gateway. The gateway fetches from core-elx (which reads from local/S3 storage) and streams chunks back. Agent stages locally, then serves via TFTP.

**`FileChunk` message**:
```protobuf
message FileChunk {
  string session_id = 1;       // Links to TftpSession
  bytes data = 2;              // File data chunk (e.g., 64KB)
  int64 offset = 3;            // Byte offset in file
  int64 total_size = 4;        // Total file size (set in first chunk, 0 if unknown)
  string content_hash = 5;     // SHA-256 hash (set in last chunk only)
  bool is_last = 6;            // True for final chunk
}
```

**Alternatives considered**:
- NATS JetStream object store — agent does not have NATS access
- Agent pushes directly to S3 — agent may lack internet access or S3 credentials
- Agent writes to shared filesystem — not available in most edge deployments
- Embed file data in CommandResult payload_json — base64 encoding doubles size, not suitable for large files
- Piggyback on ControlStream with a file_chunk payload variant — mixes control and data planes, complicates flow control

**Rationale**: gRPC streaming is the only transport the agent already has. Adding two focused RPCs (upload/download) keeps concerns separated from the control stream. The gateway acts as a relay — it has access to both the agent (gRPC) and the platform (NATS/RPC/storage). Chunk size of 64KB balances throughput with memory usage for 100MB files.

### Decision 3: Session State Machine
**Choice**: AshStateMachine on `TftpSession` resource with mode-aware states

**Receive mode** (device → agent → core):
```
configuring → queued → waiting → receiving → completed → storing → stored
                                                                    ↘ failed
```

**Serve mode** (core → agent → device):
```
configuring → queued → staging → ready → serving → completed
                                                    ↘ failed
```

**Common transitions from any active state**: → expired (timeout), → canceled (user)

**Key transitions**:
- `configuring → queued`: User submits session config in UI
- Receive: `queued → waiting`: Command sent, TFTP server started for writes
- Serve: `queued → staging`: Image download from core to agent initiated
- Serve: `staging → ready`: Image staged on agent, TFTP server started for reads
- Serve: `ready → serving`: Device connects and begins downloading
- `completed → storing`: (Receive only) Core begins writing to final storage
- `storing → stored`: File persisted to local/S3 storage

### Decision 4: Software Library Architecture
**Choice**: New `ServiceRadar.Software` Ash domain with `SoftwareImage` resource

`SoftwareImage` attributes:
- `name`, `version`, `description`, `device_type` (metadata)
- `content_hash` (SHA-256, computed on upload)
- `file_size` (bytes)
- `object_key` (storage path — filesystem or S3)
- `signature` (map — same structure as plugin packages: source, verified, reason, signer)
- `status` state machine: `uploaded → verified → active → archived → deleted`

The software library follows the existing plugin package pattern (`PluginPackage` resource + `Plugins.Storage` backend) but for firmware images instead of Wasm plugins.

### Decision 5: Dual S3 Credential Modes
**Choice**: Support both ENV-based and database-stored S3 credentials

**ENV-based** (recommended for production):
- Read from: `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`, `S3_REGION`, `S3_ENDPOINT`
- Set via Helm values, Docker Compose env, or Kubernetes secrets
- Credentials never touch the database — most secure option
- Follows existing patterns: `CLOAK_KEY`, `DATABASE_URL`, `NATS_CREDS_FILE`

**Database-stored** (for convenience / multi-tenant):
- Configured via Settings UI
- Encrypted with AshCloak using existing `ServiceRadar.Vault` (AES-256-GCM)
- Stored in `SoftwareStorageConfig` resource with `cloak do` block
- Encrypted attributes: `s3_access_key_id_encrypted`, `s3_secret_access_key_encrypted`
- Pattern follows: `AuthSettings`, `IntegrationSource`, `MapboxSettings` — all use AshCloak for API keys

**Resolution order**: ENV vars take precedence when present. If ENV vars are not set, fall back to database-stored credentials. If neither exists, S3 is unavailable (local storage only).

**Alternatives considered**:
- ENV-only — too inflexible for multi-tenant SaaS deployments
- DB-only — unnecessary risk if database is compromised; ENV is more secure for single-tenant
- HashiCorp Vault integration — over-engineered for current needs

### Decision 6: Storage Architecture
**Choice**: Dual-backend storage module (`ServiceRadar.Software.Storage`)

- **Local filesystem**: Files stored under `/var/lib/serviceradar/software/<tenant_id>/images/<image_id>/` and `/var/lib/serviceradar/software/<tenant_id>/backups/<session_id>/`
- **S3**: Uploaded via `ExAws.S3` with configurable bucket, prefix, and endpoint (supports MinIO, DigitalOcean Spaces, etc.)
- S3 object key pattern: `software/<tenant_id>/images/<image_id>/<filename>` and `software/<tenant_id>/backups/<session_id>/<filename>`
- Core-elx handles all storage operations (agents never write to S3 directly)
- HMAC-signed download URLs for secure file access (same pattern as plugin packages via `StorageToken`)

### Decision 7: Firmware Signature Verification
**Choice**: Optional signature metadata, not mandatory verification

Following the plugin package pattern:
- Uploads can include signature metadata (GPG signature, cosign signature, or just "unsigned")
- `SoftwareImage.signature` stores: `%{"source" => "upload"|"cosign", "verified" => bool, "signer" => string, "hash_algorithm" => "sha256"}`
- SHA-256 content hash is always computed and verified (mandatory)
- GPG/cosign signature verification is optional and policy-configurable
- ENV var `SOFTWARE_REQUIRE_SIGNED_IMAGES` controls enforcement (default: false)

**Rationale**: Most network operators don't have firmware signing infrastructure. SHA-256 content hash provides integrity. Signature support is available for organizations that want it, but not a barrier to adoption.

### Decision 8: Zero-Touch Provisioning Flow
**Choice**: Serve mode TFTP sessions enable ZTP

ZTP workflow:
1. Operator uploads firmware image to software library
2. Operator creates a "serve" TFTP session: selects image + target agent
3. Core sends `tftp.stage_image` command via command bus; agent calls `DownloadFile` gRPC on gateway to pull the image
4. Gateway fetches image from core (local/S3 storage) and streams to agent
5. Agent stages image locally, verifies SHA-256 hash
6. Agent starts TFTP server in read mode, serving the staged image under the configured filename
7. Network device boots/upgrades and TFTPs the image from the agent
8. Transfer completes, TFTP server stops, staged image cleaned up, session marked complete

This is not "true" ZTP (no DHCP option 66/67 integration) but provides the file-serving component that operators need alongside their existing DHCP/boot infrastructure.

### Decision 9: TFTP Server Port
**Choice**: Default to port 6969 (unprivileged) instead of standard port 69
**Rationale**: Port 69 requires root/CAP_NET_BIND_SERVICE. Using an unprivileged port avoids privilege escalation. Network operators configure their devices to use the non-standard port. Configurable via session parameters if the agent runs with sufficient privileges.

### Decision 10: Security Model
**Choice**: Defense-in-depth with multiple layers

1. **Authentication**: TFTP server only starts via authenticated command bus
2. **Authorization**: RBAC permissions gate all operations
3. **Filename allowlist**: Server rejects any filename not matching the pre-configured expected filename
4. **Size limit**: Configurable max file size (default 100MB), enforced during transfer
5. **Timeout**: Session auto-expires if no connection within timeout (default 5 min) or if transfer stalls
6. **Single-use**: Server stops after one successful transfer
7. **Bind address**: Configurable; defaults to the agent's primary interface, not 0.0.0.0
8. **Concurrency limit**: Max 1 concurrent TFTP session per agent (configurable)
9. **Audit trail**: All session and image events persisted with timestamps and actors
10. **File integrity**: SHA-256 end-to-end (agent ↔ core), verified on every transfer
11. **Serve-mode restriction**: Only serves images from the verified software library (no arbitrary file serving)
12. **S3 credential encryption**: AshCloak (AES-256-GCM) when stored in database
13. **Signature metadata**: Optional GPG/cosign for firmware provenance

### Decision 11: UI Layout
**Choice**: New "Software" tab in Settings with four sub-tabs

| Sub-tab | Purpose |
|---------|---------|
| **Library** | Upload, version, manage firmware images |
| **TFTP Sessions** | Create/monitor receive and serve sessions |
| **Storage** | Configure S3 credentials, local paths, retention |
| **Files** | Browse stored files (local + S3) |

**Rationale**: Keeps all software management in one place. Sub-tabs mirror the domain model. Similar layout to the Network tab which has Sweep Groups, Scanner Profiles, Active Scans, and Discovery sub-sections.

## Risks / Trade-offs

### Risk: TFTP is inherently insecure (no encryption, no auth)
**Mitigation**: TFTP server is ephemeral, accepts only pre-configured filenames, and auto-stops. The unencrypted hop is limited to the L2/L3 segment between device and agent. Files travel encrypted over NATS/gRPC between agent and core.

### Risk: S3 credentials stored in database could be leaked if DB is compromised
**Mitigation**: AshCloak encrypts with AES-256-GCM. The encryption key (`CLOAK_KEY`) is stored outside the database (ENV var or file). If the DB is compromised without the cloak key, credentials are unreadable. ENV-based mode avoids this risk entirely. UI shows clear guidance about which mode is more secure.

### Risk: Large firmware images could impact agent performance / gRPC throughput
**Mitigation**: Size limits (default 100MB), concurrency limits (1 session per agent). gRPC streaming with 64KB chunks provides backpressure naturally. Agent monitors memory and can abort.

### Risk: Serve mode could be abused to exfiltrate data
**Mitigation**: Serve mode only serves files from the verified software library — no arbitrary file paths. The image must be uploaded through the authenticated UI, stored in managed storage, and explicitly staged to an agent. No path traversal possible.

### Risk: Stale staged images on agents consuming disk
**Mitigation**: Staged images have a TTL. Agent cleans up staged images after session completes or expires. AshOban cleanup job ensures no orphaned files.

### Trade-off: Two S3 credential modes adds complexity
**Accepted**: The alternative is forcing all users into one mode. ENV-based is clearly more secure for single-tenant / self-hosted. DB-stored is necessary for multi-tenant SaaS or operators who can't modify environment config. The resolution-order logic (ENV > DB > disabled) is straightforward.

### Trade-off: New gRPC RPCs add proto surface area
**Accepted**: Adding `UploadFile`/`DownloadFile` to `AgentGatewayService` is the only viable transport since agents lack NATS access. The RPCs are narrowly scoped (file transfer only) and follow the existing pattern of `StreamStatus` for large payloads. The gateway relay adds a hop but is necessary for the edge architecture where agents only speak gRPC.

## Migration Plan
- No schema migrations needed for existing tables
- New Ash resources (`TftpSession`, `SoftwareImage`, `SoftwareStorageConfig`) require new tables via `mix ash.codegen`
- Add `ex_aws` and `ex_aws_s3` dependencies to core-elx `mix.exs`
- New RBAC permissions must be seeded
- Agent capability `"tftp"` is additive — existing agents without the capability are unaffected
- New ENV vars (`S3_*`) are optional — system works with local storage only if not configured
- No breaking changes to existing command bus protocol (new command types only)
- Rollback: remove capability from agent config, drop new tables, remove ExAws deps

## Open Questions

1. **File retention policy** — How long do we keep transferred files and software images? Suggest: configurable retention with default 30 days for backups, no auto-delete for library images.
2. **Multi-file sessions** — Some backup operations produce multiple files. Start with single-file, add multi-file if needed.
3. **Transfer notifications** — Should completed transfers trigger webhook/Discord notifications? Likely yes via existing alerting, but could be a follow-up.
4. **DHCP integration for true ZTP** — Should we add DHCP option 66/67 management? Out of scope for this proposal but a natural extension.
5. **Firmware diff / rollback** — Should the software library support comparing firmware versions or tracking which devices are running which version? Future consideration.
6. **S3 lifecycle policies** — Should we create S3 lifecycle rules for automatic archival? Could be configured in the storage settings.
