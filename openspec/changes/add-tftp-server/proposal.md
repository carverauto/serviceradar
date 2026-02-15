# Change: Add TFTP Server and Software Library to Agent for Network Device Firmware/Config Management

## Why
Network operators need a way to quickly pull firmware images or configuration backups off network devices (switches, routers, APs) via TFTP, AND push firmware to devices for upgrades and zero-touch provisioning (ZTP). Today, operators must manually set up a TFTP server, manage firmware files across scattered storage, and have no centralized way to track software images or verify their integrity. By embedding a TFTP server in the ServiceRadar agent — which is already deployed at the network edge — and adding a software library for firmware management, operators get a complete software lifecycle: upload firmware, verify integrity, stage on edge agents, serve via TFTP for ZTP, and receive config backups — all from the Settings UI with full audit trails.

## What Changes

### Agent (Go)
- Add a new `TFTPService` implementing the `Service` interface in `serviceradar-agent`
- Register `"tftp"` as an agent capability
- Add new command types: `tftp.start_receive`, `tftp.start_serve`, `tftp.stop_session`, `tftp.status`, `tftp.stage_image`
- **Receive mode** (device → agent): TFTP server accepts write requests for pre-authorized filenames (config backups, etc.)
- **Serve mode** (agent → device): TFTP server serves a specific staged firmware image for device download (ZTP / firmware upgrade)
- Server accepts only pre-authorized filenames in both modes
- Server auto-stops after: file transfer completes, configurable timeout expires, or explicit stop command
- Progress reporting via `CommandProgress` messages (bytes received/sent, transfer rate)
- **Image staging**: Agent downloads firmware images from gateway via new `DownloadFile` gRPC streaming RPC and stages them locally for serving
- Received files (backups) are streamed to gateway via new `UploadFile` gRPC streaming RPC

### Agent Gateway (Elixir)
- Route new TFTP command types through the existing `ControlStreamSession`
- Implement `UploadFile` gRPC handler — receive file chunks from agent, forward to core-elx via RPC
- Implement `DownloadFile` gRPC handler — fetch file from core-elx via RPC, stream chunks to agent

### Core-elx (Elixir)
- **Software Library domain** (`ServiceRadar.Software`):
  - `SoftwareImage` — Ash resource for firmware/software images with versioning, SHA-256 content hash, optional signature metadata, and lifecycle state machine (uploaded → verified → staged → archived / deleted)
  - `SoftwareStorageConfig` — Ash resource for storage configuration with dual credential modes
  - `TftpSession` — Ash resource with AshStateMachine for transfer lifecycle
- **Dual S3 credential modes**:
  - **ENV-based**: Read `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`, `S3_REGION`, `S3_ENDPOINT` from environment (Helm/Docker Compose config) — credentials never touch the database
  - **Database-stored**: Configure via Settings UI, encrypted at rest with AshCloak using existing `ServiceRadar.Vault` — for operators who prefer web-based configuration
  - System prefers ENV-based when both are present
- **File integrity**: SHA-256 content hash computed on upload, verified on download/staging. Optional GPG/cosign signature metadata (following existing plugin package pattern)
- AshOban jobs: session expiration, S3 upload, image staging to agents, retention cleanup
- RBAC permissions: `settings.software.manage`, `settings.software.view`, `software.image.upload`, `software.image.delete`, `tftp.session.create`, `tftp.session.cancel`

### Web-NG (Phoenix LiveView)
- New **Software** tab under Settings (between Network and Agents tabs)
- **Software Library sub-tab**:
  - Upload firmware images (drag-and-drop or file picker)
  - Image list with version, size, SHA-256 hash, signature status, upload date
  - Image metadata editing (description, device type, version notes)
  - Delete images (with confirmation)
  - Download images
- **TFTP Sessions sub-tab**:
  - Create receive session (device → agent): select agent, expected filename, storage destination
  - Create serve session (agent → device): select agent, select image from library, configure filename
  - Active session monitoring with real-time progress
  - Session history with filtering
- **Storage Settings sub-tab**:
  - Configure S3 credentials (when not using ENV-based)
  - View current storage mode (ENV vs database)
  - Configure local storage paths
  - File retention policy settings
- **File Browser sub-tab**:
  - Browse files in local storage and S3
  - Download, view metadata, delete

### Security Controls — **BREAKING** (new security boundaries)
- TFTP server binds only to specified interface/address (not 0.0.0.0 by default)
- Allowlisted filenames only — server rejects any filename not pre-configured
- Maximum file size enforced (configurable, default 100MB)
- Session timeout — server auto-stops after configurable duration
- Single-file sessions — one transfer per session, then server stops
- Rate limiting — max concurrent TFTP sessions per agent
- Audit logging — all session and image lifecycle events logged
- No anonymous access — TFTP server only runs when explicitly enabled via authenticated command bus
- File integrity — SHA-256 checksum computed and verified end-to-end
- Signature verification — optional GPG/cosign signature metadata for firmware images
- S3 credentials encrypted at rest with AshCloak when stored in database
- Serve mode only serves images from the verified software library (no arbitrary file serving)

## Impact
- Affected specs: `edge-architecture`, `agent-config` (new capability), new specs `tftp-server`, `software-library`
- Affected code:
  - `pkg/agent/` — new TFTPService, command handlers, image staging
  - `proto/monitoring.proto` — new command types, `UploadFile`/`DownloadFile` RPCs, `FileChunk` message (non-breaking additions)
  - `elixir/serviceradar_core/lib/serviceradar/software/` — new Ash domain
  - `elixir/serviceradar_core/lib/serviceradar/edge/` — TFTP session resources
  - `elixir/serviceradar_agent_gateway/` — file upload/download forwarding
  - `web-ng/lib/serviceradar_web_ng_web/live/settings/` — new Software tab
  - `web-ng/lib/serviceradar_web_ng_web/components/settings_components.ex` — nav update
  - `web-ng/config/runtime.exs` — S3 ENV-based credential reading
  - `elixir/serviceradar_core/mix.exs` — ExAws dependency
