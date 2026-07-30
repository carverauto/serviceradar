# Azure Storage Tests

This directory contains comprehensive tests for the Azure Storage service implementation in reqsign.

## Test Structure

```
tests/
├── credential_providers/     # Tests for different credential providers
│   ├── static_provider.rs   # SharedKey and SAS token tests
│   ├── env.rs               # Environment variable credential tests
│   ├── default.rs           # Default credential chain tests
│   ├── imds.rs              # Managed Identity (IMDS) tests
│   ├── workload_identity.rs # Kubernetes Workload Identity tests
│   ├── client_secret.rs    # Service Principal with secret tests
│   ├── client_certificate.rs # Service Principal with certificate tests
│   ├── azure_cli.rs        # Azure CLI credential tests
│   └── azure_pipelines.rs  # Azure Pipelines OIDC tests
├── signing/                 # Signature algorithm tests
│   ├── shared_key.rs       # SharedKey signature tests
│   └── sas_token.rs        # SAS token handling tests
└── mocks/                   # Mock servers for testing
    └── imds_mock.py         # Mock IMDS endpoint
```

## Running Tests Locally

### Quick Start

1. Copy the example environment file:
   ```bash
   cp .env.example .env
   ```

2. Configure your Azure credentials in `.env`

3. Run the test script:
   ```bash
   ./scripts/test-azure-storage-local.sh
   ```

### Manual Test Execution

Run all tests:
```bash
cd services/azure-storage
cargo test --no-fail-fast
```

Run specific test categories:
```bash
# Signing tests only
cargo test signing:: --no-fail-fast

# Specific credential provider
cargo test credential_providers::env:: --no-fail-fast

# Unit tests only
cargo test --lib --no-fail-fast
```

## Environment Variables

### Core Configuration

| Variable | Description | Required |
|----------|-------------|----------|
| `REQSIGN_AZURE_STORAGE_TEST` | Enable signing tests (`on`/`off`) | Yes |
| `REQSIGN_AZURE_STORAGE_URL` | Storage account URL (e.g., `https://myaccount.blob.core.windows.net/container`) | Yes |
| `REQSIGN_AZURE_STORAGE_ACCOUNT_NAME` | Storage account name | Yes |
| `REQSIGN_AZURE_STORAGE_ACCOUNT_KEY` | Storage account key (base64) | Yes |
| `REQSIGN_AZURE_STORAGE_SAS_TOKEN` | Optional SAS token for testing | No |

### Provider-Specific Flags

Enable specific credential provider tests:

| Variable | Provider | Default |
|----------|----------|---------|
| `REQSIGN_AZURE_STORAGE_TEST_ENV` | EnvCredentialProvider | `off` |
| `REQSIGN_AZURE_STORAGE_TEST_IMDS` | ImdsCredentialProvider | `off` |
| `REQSIGN_AZURE_STORAGE_TEST_WORKLOAD_IDENTITY` | WorkloadIdentityCredentialProvider | `off` |
| `REQSIGN_AZURE_STORAGE_TEST_CLI` | AzureCliCredentialProvider | `off` |
| `REQSIGN_AZURE_STORAGE_TEST_CLIENT_SECRET` | ClientSecretCredentialProvider | `off` |
| `REQSIGN_AZURE_STORAGE_TEST_CLIENT_CERTIFICATE` | ClientCertificateCredentialProvider | `off` |
| `REQSIGN_AZURE_STORAGE_TEST_PIPELINES` | AzurePipelinesCredentialProvider | `off` |

### Azure Native Environment Variables

The following Azure-native environment variables are also supported:

| Variable | Description |
|----------|-------------|
| `AZURE_STORAGE_ACCOUNT_NAME` | Storage account name |
| `AZURE_STORAGE_ACCOUNT_KEY` | Storage account key |
| `AZURE_STORAGE_SAS_TOKEN` | SAS token |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_CLIENT_ID` | Service principal client ID |
| `AZURE_CLIENT_SECRET` | Service principal secret |
| `AZURE_CLIENT_CERTIFICATE_PATH` | Path to client certificate |
| `AZURE_FEDERATED_TOKEN_FILE` | Path to federated token (K8s) |

## Mock Servers

The test suite includes mock servers for testing without Azure dependencies:

### IMDS Mock Server

Simulates the Azure Instance Metadata Service:
```bash
python3 tests/mocks/imds_mock.py 8080
```

Then run tests with:
```bash
export REQSIGN_AZURE_STORAGE_TEST_IMDS=on
export AZURE_IMDS_ENDPOINT=http://localhost:8080/metadata/identity/oauth2/token
cargo test credential_providers::imds:: --no-fail-fast
```

## GitHub Actions

Tests are automatically run in CI with the following jobs:

1. **unit_test**: Always runs, no secrets needed
2. **check_secrets**: Determines if integration tests can run
3. **signing_test**: Tests signature algorithms
4. **test_env_provider**: Tests environment variable credentials
5. **test_static_provider**: Tests static credentials
6. **test_client_secret_provider**: Tests service principal with secret
7. **test_client_certificate_provider**: Tests service principal with certificate
8. **test_azure_cli_provider**: Tests Azure CLI integration
9. **test_imds_provider_mock**: Tests IMDS with mock server

## 1Password Configuration

For CI/CD, secrets are stored in 1Password under the `reqsign/azure-storage` vault:

- `account_name`: Storage account name
- `account_key`: Storage account access key
- `sas_token`: Pre-generated SAS token
- `url`: Storage account URL
- `tenant_id`: Azure AD tenant ID
- `client_id`: Service principal client ID
- `client_secret`: Service principal secret
- `certificate_path`: Path to client certificate
- `certificate_password`: Certificate password

## Troubleshooting

### Tests are skipped

Check that environment variables are set correctly:
```bash
env | grep REQSIGN_AZURE_STORAGE
env | grep AZURE_
```

### IMDS tests fail locally

IMDS tests require running on an Azure VM or using the mock server. Use the mock server for local testing.

### Azure CLI tests fail

Ensure Azure CLI is installed and logged in:
```bash
az login
az account show
```

### Certificate tests fail

Verify the certificate file exists and has correct permissions:
```bash
ls -la $AZURE_CLIENT_CERTIFICATE_PATH
openssl pkcs12 -info -in $AZURE_CLIENT_CERTIFICATE_PATH
```

## Adding New Tests

1. Add test file in appropriate directory (`credential_providers/` or `signing/`)
2. Include module in `mod.rs`
3. Add environment variable flag if needed
4. Update GitHub Actions workflow
5. Update this README
6. Add secrets to 1Password if required
