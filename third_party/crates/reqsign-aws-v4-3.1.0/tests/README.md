# AWS V4 Integration Tests

This directory contains integration tests for the AWS V4 signing implementation, organized into two main categories.

## Test Structure

### 1. Credential Provider Tests (`credential_providers/`)

Tests for various AWS credential providers:
- `env.rs` - EnvCredentialProvider (uses AWS environment variables)
- `profile.rs` - ProfileCredentialProvider (uses AWS config/credentials files)
- `assume_role.rs` - AssumeRoleCredentialProvider
- `assume_role_with_web_identity.rs` - AssumeRoleWithWebIdentityCredentialProvider
- `cognito.rs` - CognitoIdentityCredentialProvider
- `ecs.rs` - ECSCredentialProvider
- `imds.rs` - IMDSv2CredentialProvider
- `process.rs` - ProcessCredentialProvider (not available on WASM)
- `sso.rs` - SSOCredentialProvider (not available on WASM)

### 2. Signing Tests (`signing/`)

Tests for the AWS V4 signature algorithm:
- `standard.rs` - Standard request signing (GET, PUT, HEAD, etc.)
- `special_chars.rs` - Handling of special characters in URLs
- `presigned.rs` - Pre-signed URL generation

## Running Tests

### Local Development

Use the provided test script:

```bash
# Run all available tests
./scripts/test-aws-v4-local.sh

# Or run specific tests manually
cargo test -p reqsign-aws-v4
```

### Environment Variables

#### Signing Tests
```bash
export REQSIGN_AWS_V4_TEST=on
export REQSIGN_AWS_V4_ACCESS_KEY=your_access_key
export REQSIGN_AWS_V4_SECRET_KEY=your_secret_key
export REQSIGN_AWS_V4_REGION=us-east-1
export REQSIGN_AWS_V4_SERVICE=s3
export REQSIGN_AWS_V4_URL=https://your-bucket.s3.amazonaws.com
```

#### Credential Provider Tests

Each provider has its own enable flag:

```bash
# EnvCredentialProvider
export REQSIGN_AWS_V4_TEST_ENV=on
export AWS_ACCESS_KEY_ID=your_key
export AWS_SECRET_ACCESS_KEY=your_secret

# ProfileCredentialProvider
export REQSIGN_AWS_V4_TEST_PROFILE=on
# Requires ~/.aws/credentials and ~/.aws/config

# AssumeRoleCredentialProvider
export REQSIGN_AWS_V4_TEST_ASSUME_ROLE=on
export REQSIGN_AWS_V4_ASSUME_ROLE_ARN=arn:aws:iam::123456789012:role/TestRole
# Also needs base credentials (AWS_ACCESS_KEY_ID, etc.)

# AssumeRoleWithWebIdentityCredentialProvider
export REQSIGN_AWS_V4_TEST_WEB_IDENTITY=on
export AWS_ROLE_ARN=arn:aws:iam::123456789012:role/WebIdentityRole
export AWS_WEB_IDENTITY_TOKEN_FILE=/path/to/token

# IMDSv2CredentialProvider (EC2 only)
export REQSIGN_AWS_V4_TEST_IMDS=on

# ECSCredentialProvider (ECS only)
export REQSIGN_AWS_V4_TEST_ECS=on

# SSOCredentialProvider
export REQSIGN_AWS_V4_TEST_SSO=on
# Requires SSO configuration in AWS profile

# ProcessCredentialProvider
export REQSIGN_AWS_V4_TEST_PROCESS=on
# Requires credential_process in AWS config

# CognitoIdentityCredentialProvider
export REQSIGN_AWS_V4_TEST_COGNITO=on
export REQSIGN_AWS_V4_COGNITO_IDENTITY_POOL_ID=us-east-1:xxxxx
```

## CI/CD

The GitHub Actions workflow automatically:
1. Always runs unit tests
2. Skips integration tests for forked repositories
3. Uses 1Password for secure secret management in the base repository
4. Provides a summary of test results

## Notes

- Tests gracefully skip when required environment variables are not set
- Each test outputs clear messages about what is being tested
- Use `RUST_LOG=DEBUG` for detailed logging
- Tests are designed to be independent and can run in parallel