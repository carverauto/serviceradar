# AWS V4 Mock Servers

This directory contains mock servers used for testing AWS credential providers in CI/CD environments.

## Available Mock Servers

### ECS Mock Server (`ecs_mock_server.py`)
Simulates the ECS Task IAM Roles endpoint for testing `ECSCredentialProvider`.

**Usage:**
```bash
python3 ecs_mock_server.py [port]
# Default port: 51679
```

**Endpoints:**
- `/creds` - Returns mock IAM credentials

### SSO Mock Server (`sso_mock_server.py`)
Simulates the AWS SSO (IAM Identity Center) API for testing `SSOCredentialProvider`.

**Usage:**
```bash
python3 sso_mock_server.py [port]
# Default port: 8080
```

**Endpoints:**
- `/federation/credentials` - Returns mock role credentials
  - Requires header: `x-amz-sso_bearer_token: test-access-token-for-sso`
  - Query params: `role_name` and `account_id`

### IMDS Mock Server (`imds_mock_server.py`)
Simulates the EC2 Instance Metadata Service (IMDSv2) for testing `IMDSv2CredentialProvider`.

**Usage:**
```bash
python3 imds_mock_server.py [port]
# Default port: 1338
```

**Endpoints:**
- `PUT /latest/api/token` - Get IMDSv2 session token
- `GET /latest/meta-data/iam/security-credentials/` - List available roles
- `GET /latest/meta-data/iam/security-credentials/{role}` - Get role credentials

**Note:** The IMDS test in CI currently uses the official `amazon-ec2-metadata-mock` tool instead of this Python mock.

### Credential Process Helper (`credential_process_helper.py`)
A Python script that outputs credentials in the format expected by AWS `credential_process`.

**Usage:**
```bash
python3 credential_process_helper.py [--profile <profile_name>]
```

**Output:**
Returns JSON with `Version`, `AccessKeyId`, `SecretAccessKey`, `SessionToken`, and `Expiration`.

**Example AWS Config:**
```ini
[default]
credential_process = python3 /path/to/credential_process_helper.py

[profile custom]
credential_process = python3 /path/to/credential_process_helper.py --profile test
```

### Cognito Identity Mock Server (`cognito_mock_server.py`)
Simulates the Amazon Cognito Identity service for testing `CognitoIdentityCredentialProvider`.

**Usage:**
```bash
python3 cognito_mock_server.py [port]
# Default port: 8443
```

**Endpoints:**
- `POST /` with `x-amz-target: AWSCognitoIdentityService.GetId` - Get or create identity ID
- `POST /` with `x-amz-target: AWSCognitoIdentityService.GetCredentialsForIdentity` - Get credentials for identity

**Features:**
- Supports both authenticated (with logins) and unauthenticated identities
- Returns different credentials based on authentication state
- Generates unique identity IDs for each request

## Testing

These mock servers and helpers are automatically used in GitHub Actions workflows. See `.github/workflows/aws_v4.yml` for usage examples.

## Development

When adding new mock servers:
1. Create a new Python file following the existing pattern
2. Include clear documentation in the file header
3. Support configurable port via command-line argument
4. Update this README with the new server information