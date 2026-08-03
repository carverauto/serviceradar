# Google Cloud Service Tests

This directory contains integration tests for the Google Cloud service implementation in reqsign.

## Test Structure

The tests are organized into two main categories:

### 1. Credential Providers (`credential_providers/`)
Tests for various Google Cloud credential providers:
- **DefaultCredentialProvider**: Tests the default credential chain (GOOGLE_APPLICATION_CREDENTIALS environment variable)
- **StaticCredentialProvider**: Tests loading credentials from base64-encoded JSON
- **AuthorizedUserCredentialProvider**: Tests OAuth2 user credentials (refresh token exchange)
- **ExternalAccountCredentialProvider**: Tests external account credentials (Workload Identity Federation)
- **ImpersonatedServiceAccountCredentialProvider**: Tests service account impersonation
- **VmMetadataCredentialProvider**: Tests fetching credentials from GCP VM metadata service (only available on GCP VMs)

### 2. Signing Tests (`signing/`)
Tests for request signing functionality:
- **Standard signing**: Tests OAuth2 bearer token signing for GCS API requests
- **Signed URLs**: Tests generating pre-signed URLs for GCS objects

## Environment Variables

### Core Test Control
- `REQSIGN_GOOGLE_TEST`: Set to `on` to enable signing tests
- `REQSIGN_GOOGLE_TEST_DEFAULT`: Set to `on` to enable DefaultCredentialProvider tests
- `REQSIGN_GOOGLE_TEST_STATIC`: Set to `on` to enable StaticCredentialProvider tests
- `REQSIGN_GOOGLE_TEST_AUTHORIZED_USER`: Set to `on` to enable AuthorizedUserCredentialProvider tests
- `REQSIGN_GOOGLE_TEST_AUTHORIZED_USER_GCLOUD`: Set to `on` to test gcloud authorized user credentials
- `REQSIGN_GOOGLE_TEST_EXTERNAL_ACCOUNT`: Set to `on` to enable ExternalAccountCredentialProvider tests with test data
- `REQSIGN_GOOGLE_TEST_WORKLOAD_IDENTITY`: Set to `on` to enable real Workload Identity tests
- `REQSIGN_GOOGLE_TEST_IMPERSONATED_SERVICE_ACCOUNT`: Set to `on` to enable ImpersonatedServiceAccountCredentialProvider tests
- `REQSIGN_GOOGLE_TEST_IMPERSONATION_REAL`: Set to `on` to test with real impersonation credentials
- `REQSIGN_GOOGLE_TEST_IMPERSONATION_DELEGATES`: Set to `on` to test impersonation with delegation chain
- `REQSIGN_GOOGLE_TEST_VM_METADATA`: Set to `on` to enable VmMetadataCredentialProvider tests (GCP VMs only)
- `REQSIGN_GOOGLE_TEST_VM_METADATA_MOCK`: Set to `on` to enable VmMetadataCredentialProvider tests with the local mock server

### Google Cloud Configuration
- `GOOGLE_APPLICATION_CREDENTIALS`: Path to credential JSON file (supports all credential types)
- `REQSIGN_GOOGLE_CREDENTIAL`: Base64-encoded service account JSON (for StaticCredentialProvider)
- `REQSIGN_GOOGLE_CLOUD_STORAGE_SCOPE`: OAuth2 scope for GCS (e.g., `https://www.googleapis.com/auth/devstorage.read_write`)
- `REQSIGN_GOOGLE_CLOUD_STORAGE_URL`: GCS bucket URL (e.g., `https://storage.googleapis.com/storage/v1/b/your-bucket`)
- `GOOGLE_IMPERSONATED_CREDENTIALS`: Path to impersonated service account credential file
- `GOOGLE_WORKLOAD_IDENTITY_PROVIDER`: Workload Identity Provider ID (for GitHub Actions)
- `GOOGLE_SERVICE_ACCOUNT`: Service account email for Workload Identity

## Running Tests

### Local Development

1. Copy `.env.example` to `.env` in the repository root
2. Configure your Google Cloud credentials in the `.env` file
3. Run tests using the provided script:
   ```bash
   cd services/google
   ./scripts/test.sh
   ```

Or run specific test suites:
```bash
# Run only signing tests
REQSIGN_GOOGLE_TEST=on cargo test signing::

# Run only DefaultCredentialProvider tests
REQSIGN_GOOGLE_TEST_DEFAULT=on cargo test test_default_credential_provider

# Run all credential provider tests
cargo test credential_providers::
```

### GitHub Actions

The tests are automatically run in GitHub Actions with the following setup:
- Unit tests run on all PRs (no secrets required)
- Integration tests only run on the main repository (not on forks)
- Credentials are managed through 1Password Connect

## 1Password Configuration

The following secrets need to be configured in 1Password under the `reqsign/google` item:

| Field | Description | Example |
|-------|-------------|---------|
| `credential_json` | Service account JSON content | `{"type": "service_account", ...}` |
| `credential_base64` | Base64-encoded service account JSON | `eyJ0eXBlIjogInNlcnZpY2VfYWNjb3VudCIsIC4uLn0=` |
| `storage_scope` | OAuth2 scope for GCS | `https://www.googleapis.com/auth/devstorage.read_write` |
| `storage_url` | GCS bucket URL for testing | `https://storage.googleapis.com/storage/v1/b/test-bucket` |

## Creating Test Credentials

1. Create a service account in Google Cloud Console
2. Grant the service account appropriate permissions (e.g., Storage Object Admin)
3. Create and download a JSON key for the service account
4. For base64 encoding: `base64 -i service-account.json | tr -d '\n'`

## Credential Types Support

Google Cloud supports multiple credential types:

1. **Service Account**: Standard service account with private key
2. **Authorized User**: OAuth2 user credentials from `gcloud auth application-default login`
3. **External Account**: Workload Identity Federation (GitHub Actions, AWS, Azure, etc.)
4. **Impersonated Service Account**: Service account impersonation with delegation chain
5. **VM Metadata**: Credentials from GCP VM metadata service

The DefaultCredentialProvider automatically detects and handles all these types.

## Notes

- The VmMetadataCredentialProvider tests are disabled by default in CI as they require running on actual GCP VMs
- CI runs a separate VmMetadataCredentialProvider test via the mock metadata server
- External Account tests can run in GitHub Actions with proper Workload Identity setup
- Impersonation tests require proper IAM permissions for the source credentials
- Tests use real GCS API endpoints to verify signature validity
- All tests are designed to be idempotent and safe to run repeatedly
- Some credential provider tests use test data that will fail token exchange - this is expected

## Local STS Mock

For local development without real Google Cloud credentials, you can run a simple STS mock:

```bash
python3 services/google/tests/mocks/sts_mock_server.py 5000
```

The example credential file `services/google/testdata/test_external_account.json` is configured to use this mock.
