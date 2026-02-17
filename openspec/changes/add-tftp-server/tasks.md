## 1. Proto & Shared Types
- [x] 1.1 Add TFTP command type constants to proto documentation / agent constants (`tftp.start_receive`, `tftp.start_serve`, `tftp.stop_session`, `tftp.status`, `tftp.stage_image`)
- [x] 1.2 Define TFTP payload JSON schemas (start_receive, start_serve, stop_session, status, stage_image payloads)
- [x] 1.3 Add `UploadFile` and `DownloadFile` RPCs to `AgentGatewayService` in `monitoring.proto`
- [x] 1.4 Define `FileChunk`, `FileUploadResponse`, `FileDownloadRequest` messages in `monitoring.proto`

## 2. Agent — TFTP Service (Go)
- [x] 2.1 Add `pin/tftp` dependency to Go modules
- [x] 2.2 Create `pkg/agent/tftp_service.go` implementing `Service` interface
- [x] 2.3 Implement TFTP write handler (receive mode) with filename allowlist enforcement
- [x] 2.4 Implement TFTP read handler (serve mode) serving only staged library images
- [x] 2.5 Implement file size limit enforcement during transfer (both modes)
- [x] 2.6 Implement session timeout (auto-stop if no connection within timeout)
- [x] 2.7 Implement transfer progress reporting via `CommandProgress` messages (both modes)
- [x] 2.8 Implement SHA-256 checksum computation during receive transfers
- [x] 2.9 Implement file staging to temporary directory with cleanup
- [x] 2.10 Implement file upload via `UploadFile` gRPC streaming RPC (receive: agent→gateway→core)
- [x] 2.11 Implement image download via `DownloadFile` gRPC streaming RPC (serve: core→gateway→agent staging)
- [x] 2.12 Add `tftp.start_receive` command handler to `control_stream.go`
- [x] 2.13 Add `tftp.start_serve` command handler to `control_stream.go`
- [x] 2.14 Add `tftp.stop_session` command handler to `control_stream.go`
- [x] 2.15 Add `tftp.status` command handler to `control_stream.go`
- [x] 2.16 Add `tftp.stage_image` command handler to `control_stream.go`
- [x] 2.17 Register `"tftp"` in `getAgentCapabilities()`
- [x] 2.18 Add bind-address configuration (default: agent primary interface, not 0.0.0.0)
- [x] 2.19 Add concurrency limit enforcement (max 1 session per agent)
- [x] 2.20 Add staged image TTL and cleanup
- [x] 2.21 Write unit tests for TFTP service (receive mode)
- [x] 2.22 Write unit tests for TFTP service (serve mode)
- [x] 2.23 Write integration tests for TFTP command handlers

## 3. Agent Gateway — Command Routing & File Transfer
- [x] 3.1 Verify TFTP command types route through existing `ControlStreamSession` (likely no code changes needed)
- [x] 3.2 Implement `UploadFile` gRPC handler — receive file chunks from agent, buffer/stream to core-elx via RPC
- [x] 3.3 Implement `DownloadFile` gRPC handler — fetch file from core-elx via RPC, stream chunks to agent
- [x] 3.4 Add file transfer rate limiting / backpressure at gateway level
- [x] 3.5 Test command flow: core → gateway → agent → gateway → core for TFTP lifecycle (both modes)
- [x] 3.6 Test file transfer flow: agent ↔ gateway ↔ core for upload and download

## 4. Core-elx — S3 Integration & Storage
- [x] 4.1 Add `ex_aws`, `ex_aws_s3`, `hackney` (or `sweet_xml`) dependencies to core-elx `mix.exs`
- [x] 4.2 Create `ServiceRadar.Software.Storage` module with dual-backend support (local + S3)
- [x] 4.3 Implement local filesystem storage backend (put, get, delete, list)
- [x] 4.4 Implement S3 storage backend via ExAws.S3 (put, get, delete, list, presigned URLs)
- [x] 4.5 Implement S3 credential resolution: ENV vars → DB-stored (AshCloak) → disabled
- [x] 4.6 Add S3 ENV vars to `runtime.exs`: `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`, `S3_REGION`, `S3_ENDPOINT`
- [x] 4.7 Implement HMAC-signed download URLs (following `StorageToken` pattern from plugin packages)
- [x] 4.8 Implement SHA-256 content hash computation and verification
- [x] 4.9 Write tests for storage backends (local + S3)

## 5. Core-elx — Software Library Domain
- [x] 5.1 Create `ServiceRadar.Software` Ash domain module
- [x] 5.2 Create `SoftwareImage` Ash resource with AshStateMachine (uploaded → verified → active → archived → deleted)
- [x] 5.3 Add `SoftwareImage` attributes: name, version, description, device_type, content_hash, file_size, object_key, signature (map), status
- [x] 5.4 Add `SoftwareImage` actions: create (upload), verify, activate, archive, delete, list, read
- [x] 5.5 Create `SoftwareStorageConfig` Ash resource with AshCloak for S3 credentials
- [x] 5.6 Add AshCloak `cloak do` block: vault `ServiceRadar.Vault`, encrypt `s3_access_key_id_encrypted`, `s3_secret_access_key_encrypted`
- [x] 5.7 Add `SoftwareStorageConfig` attributes: storage_mode (local/s3/both), s3_bucket, s3_region, s3_endpoint, s3_prefix, local_path, retention_days
- [x] 5.8 Add RBAC policies to `SoftwareImage` and `SoftwareStorageConfig`
- [x] 5.9 Add optional signature verification policy (ENV var `SOFTWARE_REQUIRE_SIGNED_IMAGES`)
- [x] 5.10 Generate Ash migrations via `mix ash.codegen add_software_library`
- [x] 5.11 Write tests for SoftwareImage state machine transitions
- [x] 5.12 Write tests for SoftwareStorageConfig credential resolution

## 6. Core-elx — TFTP Session Management
- [x] 6.1 Create `TftpSession` Ash resource with AshStateMachine (mode-aware states)
- [x] 6.2 Define receive-mode transitions: configuring → queued → waiting → receiving → completed → storing → stored / failed
- [x] 6.3 Define serve-mode transitions: configuring → queued → staging → ready → serving → completed / failed
- [x] 6.4 Define common transitions: any active → expired / canceled
- [x] 6.5 Add `TftpSession` attributes: mode (receive/serve), agent_id, expected_filename, storage_destination, timeout_seconds, image_id (for serve), notes, file_size, content_hash
- [x] 6.6 Add RBAC policies to `TftpSession`
- [x] 6.7 Create Ash change hook `DispatchTftpStart` to send command via `AgentCommandBus` on queue
- [x] 6.8 Create Ash change hook `DispatchTftpStop` to send stop command on cancel
- [x] 6.9 Create Ash change hook `DispatchTftpStage` to stage image to agent for serve-mode sessions
- [x] 6.10 Add TFTP event handling to `AgentCommands.StatusHandler` for session state transitions
- [x] 6.11 Create AshOban job for session expiration (expire sessions past timeout)
- [x] 6.12 Create AshOban job for async S3 upload (receive-mode completed files)
- [x] 6.13 Create AshOban job for image staging to agents (serve-mode)
- [x] 6.14 Create AshOban job for retention cleanup (delete expired backups)
- [x] 6.15 Implement file reception from gateway RPC (receive mode — gateway forwards upload to core)
- [x] 6.16 Implement image serving to gateway RPC (serve mode — core serves file for gateway to stream to agent)
- [x] 6.17 Add `"tftp"` to recognized agent capabilities in `AgentCommandBus`
- [x] 6.18 Add convenience wrappers to `AgentCommandBus`: `start_tftp_receive/2`, `start_tftp_serve/2`, `stop_tftp_session/2`, `stage_tftp_image/2`
- [x] 6.19 Seed RBAC permissions: `settings.software.manage`, `settings.software.view`, `software.image.upload`, `software.image.delete`, `tftp.session.create`, `tftp.session.cancel`
- [x] 6.20 Generate Ash migrations via `mix ash.codegen add_tftp_sessions`
- [x] 6.21 Write tests for TftpSession state machine transitions (both modes)
- [x] 6.22 Write tests for command dispatch hooks

## 7. Web-NG — Software Tab & Navigation
- [x] 7.1 Add "Software" tab to settings navigation in `settings_components.ex`
- [x] 7.2 Add RBAC permission check for Software tab visibility
- [x] 7.3 Create `Settings.SoftwareLive.Index` LiveView module with sub-tab routing
- [x] 7.4 Add routes for Software settings in `router.ex` (library, sessions, storage, files)

## 8. Web-NG — Software Library UI
- [x] 8.1 Build image upload form with drag-and-drop / file picker (using LiveView uploads)
- [x] 8.2 Build image metadata form (name, version, description, device_type)
- [x] 8.3 Compute and display SHA-256 content hash on upload
- [x] 8.4 Build image list table (name, version, size, hash, signature status, status, date)
- [x] 8.5 Build image detail view with full metadata and signature info
- [x] 8.6 Add image actions: verify, activate, archive, delete (with confirmation)
- [x] 8.7 Add image download via HMAC-signed URL
- [x] 8.8 Add optional signature metadata input on upload

## 9. Web-NG — TFTP Sessions UI
- [x] 9.1 Build receive-session creation form (agent selector, filename, storage destination, timeout, notes)
- [x] 9.2 Build serve-session creation form (agent selector, image from library, filename override, timeout)
- [x] 9.3 Agent selector: filter to agents with `tftp` capability
- [x] 9.4 Subscribe to PubSub for live session status updates
- [x] 9.5 Build active session monitoring panel with real-time status
- [x] 9.6 Build progress bar component for active transfers (bytes, rate, ETA)
- [x] 9.7 Build session history table with status filtering and pagination
- [x] 9.8 Add session cancel action with confirmation dialog

## 10. Web-NG — Storage Settings UI
- [x] 10.1 Build storage configuration form
- [x] 10.2 Display current credential mode (ENV-based vs database, with clear security guidance)
- [x] 10.3 Build S3 credential input form (only shown when not using ENV-based)
- [x] 10.4 Add S3 connection test button (verify credentials work)
- [x] 10.5 Build local storage path configuration
- [x] 10.6 Build retention policy configuration (days to keep backups)

## 11. Web-NG — File Browser UI
- [x] 11.1 Build file browser component listing stored files (local + S3)
- [x] 11.2 Display file metadata (name, size, date, checksum, source session)
- [x] 11.3 Add file download action (local: direct, S3: presigned URL)
- [x] 11.4 Add file delete action with confirmation
- [x] 11.5 Add filtering by file type (backup vs image), date range, agent

## 12. Security & Hardening
- [x] 12.1 Audit TFTP service for security: filename validation, path traversal prevention
- [x] 12.2 Ensure TFTP server binds to configured interface only
- [x] 12.3 Verify file size limits enforced at agent level (both modes)
- [x] 12.4 Verify SHA-256 checksum end-to-end (agent ↔ core)
- [x] 12.5 Verify session timeout enforcement
- [x] 12.6 Verify RBAC permissions block unauthorized access at all layers
- [x] 12.7 Add audit log entries for all session and image lifecycle events
- [x] 12.8 Test concurrent session rejection (max 1 per agent)
- [x] 12.9 Test with malicious filenames (path traversal, special characters, unicode)
- [x] 12.10 Test with oversized files (verify limit enforcement)
- [x] 12.11 Verify serve mode only serves library images (no arbitrary files)
- [x] 12.12 Verify AshCloak encryption of S3 credentials in database
- [x] 12.13 Verify ENV-based credentials are never written to database
- [x] 12.14 Test S3 credential resolution order (ENV > DB > disabled)
- [x] 12.15 Test staged image cleanup on session completion/expiration

## 13. Documentation & Integration Tests
- [ ] 13.1 Write end-to-end test: receive mode (UI → core → gateway → agent → TFTP receive → storage)
- [ ] 13.2 Write end-to-end test: serve mode (upload image → stage to agent → TFTP serve → device download)
- [ ] 13.3 Write end-to-end test: session timeout/expiration flow
- [ ] 13.4 Write end-to-end test: session cancellation flow
- [ ] 13.5 Write end-to-end test: S3 storage (both credential modes)
- [ ] 13.6 Test with actual network device TFTP client (or simulated)
