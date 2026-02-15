## ADDED Requirements

### Requirement: Software Image Management
The system SHALL provide a software library for uploading, versioning, and managing firmware and software images. Each image MUST be tracked as a `SoftwareImage` Ash resource with metadata (name, version, description, device type), a SHA-256 content hash, file size, and optional signature metadata. Images MUST follow a lifecycle state machine: uploaded → verified → active → archived → deleted.

#### Scenario: Upload a firmware image
- **WHEN** an authenticated operator with `software.image.upload` permission uploads a firmware image via the Settings UI
- **THEN** a `SoftwareImage` resource is created in `uploaded` state
- **AND** the SHA-256 content hash is computed and stored
- **AND** the file is persisted to the configured storage backend (local or S3)

#### Scenario: Verify and activate an image
- **WHEN** an operator verifies an uploaded image (confirming it is the correct firmware)
- **THEN** the image transitions from `uploaded` to `verified`
- **AND** the operator can then activate the image, transitioning it to `active`
- **AND** active images are available for selection in serve-mode TFTP sessions

#### Scenario: Archive an image
- **WHEN** an operator archives an active image (superseded by a newer version)
- **THEN** the image transitions to `archived`
- **AND** the image is no longer selectable for new TFTP serve sessions
- **AND** the file remains in storage for historical reference

#### Scenario: Delete an image
- **WHEN** an operator with `software.image.delete` permission deletes an image
- **THEN** the image transitions to `deleted`
- **AND** the file is removed from storage (local and/or S3)

### Requirement: Software Image Integrity
Every software image MUST have a SHA-256 content hash computed at upload time. The hash MUST be verified when images are downloaded, staged to agents, or served via TFTP. Hash mismatches MUST cause the operation to fail with a clear error.

#### Scenario: Hash computed on upload
- **WHEN** a software image is uploaded
- **THEN** the SHA-256 hash of the file contents is computed and stored in the `SoftwareImage` resource

#### Scenario: Hash verified on staging
- **WHEN** an image is staged to an agent for TFTP serving
- **THEN** the agent verifies the SHA-256 hash matches the expected value from the `SoftwareImage` resource
- **AND** if the hash does not match, staging fails and the session transitions to `failed`

### Requirement: Software Image Signature Metadata
The system SHALL support optional signature metadata for software images, following the existing plugin package pattern. Signature metadata MUST include source, verification status, signer identity, and hash algorithm. Signature enforcement MUST be configurable via the `SOFTWARE_REQUIRE_SIGNED_IMAGES` environment variable (default: false).

#### Scenario: Upload with signature metadata
- **WHEN** an operator uploads a firmware image with accompanying signature metadata (GPG signature, cosign signature, etc.)
- **THEN** the signature metadata is stored in the `SoftwareImage.signature` map attribute
- **AND** the verification status is recorded

#### Scenario: Unsigned upload when signatures not required
- **WHEN** `SOFTWARE_REQUIRE_SIGNED_IMAGES` is false and an operator uploads an image without signature metadata
- **THEN** the upload succeeds with `signature` set to `%{"source" => "upload", "verified" => false}`

#### Scenario: Unsigned upload rejected when signatures required
- **WHEN** `SOFTWARE_REQUIRE_SIGNED_IMAGES` is true and an operator uploads an image without valid signature metadata
- **THEN** the upload is rejected with an error indicating signature is required

### Requirement: Dual S3 Credential Modes
The system SHALL support two modes for S3 credential management: ENV-based and database-stored. ENV-based credentials MUST be read from environment variables (`S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`, `S3_REGION`, `S3_ENDPOINT`). Database-stored credentials MUST be encrypted with AshCloak using `ServiceRadar.Vault`. ENV-based credentials MUST take precedence when both are configured.

#### Scenario: ENV-based S3 credentials
- **WHEN** S3 environment variables are set (via Helm, Docker Compose, or Kubernetes secrets)
- **THEN** the system uses ENV-based credentials for all S3 operations
- **AND** the Settings UI displays "S3 configured via environment" with no credential input form
- **AND** credentials are never written to the database

#### Scenario: Database-stored S3 credentials
- **WHEN** S3 environment variables are NOT set and an operator configures S3 credentials via the Settings UI
- **THEN** the credentials are encrypted with AshCloak (AES-256-GCM) and stored in the `SoftwareStorageConfig` resource
- **AND** the system uses database-stored credentials for S3 operations

#### Scenario: Credential resolution order
- **WHEN** the system needs S3 credentials for a storage operation
- **THEN** it checks ENV vars first, then database-stored credentials, then reports S3 as unavailable
- **AND** ENV-based credentials always take precedence over database-stored

#### Scenario: No S3 credentials configured
- **WHEN** neither ENV vars nor database-stored S3 credentials are configured
- **THEN** S3 storage is unavailable
- **AND** the system falls back to local filesystem storage only
- **AND** the Settings UI displays a message indicating S3 is not configured

### Requirement: Software Storage Backends
The system SHALL support two storage backends for software images and TFTP backups: local filesystem and S3-compatible object storage. The storage configuration MUST be per-tenant via the `SoftwareStorageConfig` Ash resource. Core-elx MUST handle all storage operations.

#### Scenario: Local filesystem storage
- **WHEN** storage is configured for local filesystem
- **THEN** files are stored under `/var/lib/serviceradar/software/<tenant_id>/`
- **AND** images under `images/<image_id>/` and backups under `backups/<session_id>/`

#### Scenario: S3 storage
- **WHEN** storage is configured for S3
- **THEN** files are uploaded to the configured S3 bucket with key prefix `software/<tenant_id>/`
- **AND** the system supports S3-compatible endpoints (AWS S3, MinIO, DigitalOcean Spaces)

#### Scenario: HMAC-signed download URLs
- **WHEN** a user requests to download a file from storage
- **THEN** the system generates an HMAC-signed URL with a configurable TTL
- **AND** the URL is validated on access to prevent unauthorized downloads

### Requirement: Software Library UI
The Settings Software tab MUST include a Library sub-tab for managing software images. The UI MUST support image upload with drag-and-drop, metadata editing, lifecycle actions, and download.

#### Scenario: Image upload via UI
- **WHEN** an operator navigates to the Library sub-tab and uploads a file
- **THEN** the file is uploaded via LiveView chunked uploads
- **AND** a metadata form collects name, version, description, and device type
- **AND** the SHA-256 hash is displayed after upload completes

#### Scenario: Image list view
- **WHEN** an operator views the Library sub-tab
- **THEN** a table displays all images with columns: name, version, size, hash (truncated), signature status, lifecycle status, upload date
- **AND** the table supports filtering by status and device type

#### Scenario: Image download
- **WHEN** an operator clicks download on an image
- **THEN** a secure download is initiated via HMAC-signed URL

### Requirement: Storage Settings UI
The Settings Software tab MUST include a Storage sub-tab for configuring storage backends and S3 credentials. The UI MUST clearly indicate whether S3 credentials are ENV-based or database-stored, with security guidance.

#### Scenario: ENV-based credential display
- **WHEN** S3 credentials are configured via environment variables
- **THEN** the Storage sub-tab displays "S3 credentials configured via environment (recommended)"
- **AND** no credential input form is shown
- **AND** the S3 bucket, region, and endpoint are displayed (read from ENV)

#### Scenario: Database credential configuration
- **WHEN** S3 credentials are NOT configured via environment and an operator opens the Storage sub-tab
- **THEN** a form is displayed for entering S3 access key, secret key, bucket, region, and endpoint
- **AND** a security notice explains that credentials will be encrypted but ENV-based is recommended for production
- **AND** a "Test Connection" button verifies the credentials work

#### Scenario: Retention policy configuration
- **WHEN** an operator configures the retention policy
- **THEN** a setting controls how many days to retain TFTP backup files (default: 30)
- **AND** an AshOban job automatically deletes expired backups

### Requirement: File Browser UI
The Settings Software tab MUST include a Files sub-tab for browsing files stored locally and in S3. The browser MUST display file metadata and support download and deletion.

#### Scenario: Browse local files
- **WHEN** an operator opens the Files sub-tab
- **THEN** files from local storage are listed with name, size, date, checksum, and source (which session or image)

#### Scenario: Browse S3 files
- **WHEN** S3 is configured and the operator selects the S3 view
- **THEN** files from the S3 bucket are listed with name, size, last modified, and storage class

#### Scenario: File download
- **WHEN** an operator clicks download on a file
- **THEN** a secure download is initiated (local: direct stream, S3: presigned URL)

#### Scenario: File deletion
- **WHEN** an operator with `settings.software.manage` permission deletes a file
- **THEN** the file is removed from storage after confirmation
- **AND** the deletion is logged as an audit event
