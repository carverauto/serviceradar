---
sidebar_position: 10
title: Authentication Configuration
---

# Authentication Configuration

ServiceRadar supports user authentication to secure access to the monitoring dashboard and API. This guide explains how to configure authentication options, including the local user authentication system.

## RS256 + JWKS (for API Gateways)

For deployments behind an API Gateway (e.g., Apache APISIX), you can switch JWT signing to RS256 and expose a JWKS endpoint so the gateway validates tokens without sharing secrets.

Add these fields under `auth` in `core.json`:

```json
"auth": {
  "jwt_algorithm": "RS256",
  "jwt_private_key_pem": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
  "jwt_key_id": "main-2025-09",
  "jwt_expiration": "24h"
}
```

The core service will serve:
- `/.well-known/openid-configuration` with a `jwks_uri` pointing to
- `/auth/jwks.json` containing the RSA public key set

Gateways can use these endpoints to validate `Authorization: Bearer <token>` without contacting the core on every request.

## Overview

ServiceRadar's authentication system provides:
- Local user authentication with secure password storage
- JWT (JSON Web Token) based sessions
- Configurable token expiration
- CORS (Cross-Origin Resource Sharing) settings for API security

## Authentication Configuration

Authentication is configured in the core service configuration file (`/etc/serviceradar/core.json`) under the `auth` section:

```json
"auth": {
    "jwt_secret": "your-secret-key-here",
    "jwt_expiration": "24h",
    "local_users": {
        "admin": "$2a$18$8cTFzZ6ISuSrxCeO1oL9EOc/zy.cvGO9GhsE9jVo2i.tCzsasdadf"
    }
}
```

### Configuration Options

| Option | Description | Default | Required |
|--------|-------------|---------|----------|
| `jwt_secret` | Secret key used to sign JWT tokens | N/A | Yes |
| `jwt_expiration` | Token validity duration (e.g., "24h", "7d") | `"24h"` | No |
| `local_users` | Map of username to bcrypt-hashed passwords | `{}` | No |

## Local User Authentication

ServiceRadar supports local user authentication with usernames and bcrypt-hashed passwords. This is a simple and secure method for small deployments where external authentication systems are not required.

### Adding Local Users

Local users are defined in the `local_users` map, where each key is a username and each value is a bcrypt-hashed password.

#### Generating Password Hashes

You can generate bcrypt password hashes using various tools:

1. **Using the ServiceRadar CLI tool**:
```bash
serviceradar-tools hash-password "your-password-here"
```

2. **Using Python**:
```python
import bcrypt
password = "your-password-here"
salt = bcrypt.gensalt(10)  # Cost factor of 10
hashed = bcrypt.hashpw(password.encode(), salt)
print(hashed.decode())
```

3. **Using Node.js**:
```javascript
const bcrypt = require('bcrypt');
const password = "your-password-here";
const saltRounds = 10;
bcrypt.hash(password, saltRounds, function(err, hash) {
    console.log(hash);
});
```

### Example Configuration

Here's an example configuration with multiple local users:

```json
"auth": {
    "jwt_secret": "random-secure-secret-key",
    "jwt_expiration": "8h",
    "local_users": {
        "admin": "$2a$10$7cTFzX6ISkSrxCeO1ZL2EOc/zy.cvGO9GhsE9jVo2i.tCzsiowoiC",
        "operator": "$2a$10$1xJ0APzN9X7KVXGn1VUGzu9KUb2CV4QNjr0REQ6Kc9ByWbmOSgiS2",
        "readonly": "$2a$10$t4XyaM3FGl9KGCqUJWZVreo4YWN7.CFsvGFuQ0H0JfylEJd0IMPZa"
    }
}
```

> **Security Note:** Always use a strong, random string for `jwt_secret` and never share it. This key is used to sign authentication tokens, and if compromised, could allow unauthorized access to your ServiceRadar instance.

## CORS Configuration

Cross-Origin Resource Sharing (CORS) settings control which domains can access your ServiceRadar API. This is important when your web UI is hosted on a different domain than your API.

```json
"cors": {
    "allowed_origins": ["https://demo-staging.serviceradar.cloud", "http://localhost:3000"],
    "allow_credentials": true
}
```

### Configuration Options

| Option | Description | Default | Required |
|--------|-------------|---------|----------|
| `allowed_origins` | List of allowed origins (domains) | `["*"]` | No |
| `allow_credentials` | Whether credentials are allowed | `false` | No |

## Login Workflow

The authentication workflow for ServiceRadar:

1. User sends credentials (username and password) to `/api/auth/login`
2. The system validates credentials against configured local users
3. If valid, a JWT token is issued with the configured expiration time
4. The client includes this token in subsequent requests in the `Authorization` header
5. The token is automatically refreshed during active sessions

## Security Best Practices

1. **Use Strong Passwords**: Ensure all user accounts have strong, unique passwords.

2. **Change Default Credentials**: Always change the default admin password after installation.

3. **Use HTTPS**: Configure your web server to use HTTPS to encrypt authentication traffic.

4. **Set Appropriate Token Expiration**: Balance security and convenience by setting an appropriate JWT expiration time.

5. **Limit Allowed Origins**: In production, specify only the domains that need to access your API in the `allowed_origins` list.

6. **Rotate JWT Secret**: Periodically update your `jwt_secret` to mitigate the risk of token-based attacks.

## Troubleshooting

### Authentication Failures

If users are unable to log in:

1. Verify the username exists in the `local_users` map
2. Check that the password hash is correctly formatted (bcrypt format)
3. Ensure the `jwt_secret` has not been changed since the token was issued
4. Verify the token has not expired (based on `jwt_expiration` setting)

### CORS Issues

If web clients receive CORS errors:

1. Check that the client's domain is included in the `allowed_origins` list
2. Verify the `allow_credentials` setting matches your requirements
3. Ensure the client is properly sending the required CORS headers

### Viewing Active Sessions

Currently, ServiceRadar does not provide a UI for viewing active sessions. If you need to force logout a user, you can:

1. Change the `jwt_secret` (which will invalidate all existing tokens)
2. Restart the core service

## Next Steps

- Learn more about [ServiceRadar Sync Service](./sync.md)
- Set up [TLS Security](./tls-security.md) for secure communications
