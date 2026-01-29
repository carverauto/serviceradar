---
sidebar_position: 13
title: Gateway Authentication Setup
---

# Gateway/Proxy JWT Authentication Setup

This guide explains how to configure ServiceRadar to trust JWT tokens from an upstream authentication gateway or reverse proxy, such as Kong, Traefik, NGINX with auth modules, or cloud-native solutions like AWS ALB or Google Cloud IAP.

## Overview

In gateway authentication mode, ServiceRadar trusts an upstream proxy to handle authentication. The proxy validates user credentials and injects a signed JWT into requests forwarded to ServiceRadar.

```
User → Gateway (Auth) → ServiceRadar (Trust JWT)
```

This is useful for:
- Centralized authentication across multiple services
- Leveraging existing API gateway infrastructure
- Cloud-native authentication (AWS Cognito, Google IAP, Azure AD)
- Zero-trust network architectures

## Prerequisites

- Admin access to ServiceRadar
- Admin access to your authentication gateway
- Your gateway must be able to inject signed JWTs into request headers

## Authentication Flow

1. User authenticates with the gateway (OIDC, SAML, etc.)
2. Gateway creates a signed JWT with user claims
3. Gateway forwards requests to ServiceRadar with the JWT in a header
4. ServiceRadar validates the JWT signature using the gateway's public key
5. ServiceRadar extracts user information and creates a session

## Step 1: Configure Your Gateway

### Kong Gateway

1. Enable the JWT or OIDC plugin on your ServiceRadar route
2. Configure the plugin to inject the token in a header:

```yaml
plugins:
  - name: openid-connect
    config:
      issuer: https://your-idp.com/
      client_id: your-client-id
      client_secret: your-client-secret
      upstream_headers_claims:
        - Authorization
      upstream_headers_types:
        - bearer
```

Or with custom header:

```yaml
plugins:
  - name: jwt
    config:
      header_names:
        - X-Auth-Token
```

### Traefik

Use the ForwardAuth middleware with an authentication service:

```yaml
http:
  middlewares:
    auth:
      forwardAuth:
        address: "http://auth-service/verify"
        authResponseHeaders:
          - "X-Auth-Token"
          - "X-Auth-User"

  routers:
    serviceradar:
      rule: "Host(`serviceradar.example.com`)"
      middlewares:
        - auth
      service: serviceradar
```

### NGINX with OAuth2 Proxy

```nginx
location / {
    auth_request /oauth2/auth;
    error_page 401 = /oauth2/sign_in;

    auth_request_set $user $upstream_http_x_auth_request_user;
    auth_request_set $token $upstream_http_x_auth_request_access_token;

    proxy_set_header X-Auth-Token $token;
    proxy_set_header X-Auth-User $user;
    proxy_pass http://serviceradar:4000;
}
```

### AWS Application Load Balancer (ALB)

ALB with Cognito authentication automatically injects tokens:

1. Configure ALB authentication action with Cognito
2. ALB injects `x-amzn-oidc-accesstoken` and `x-amzn-oidc-data` headers
3. Configure ServiceRadar to read from these headers

### Google Cloud IAP

IAP automatically injects a signed JWT:

1. Enable IAP on your Cloud Run/GKE service
2. IAP injects `x-goog-iap-jwt-assertion` header
3. Configure ServiceRadar with Google's public keys

## Step 2: Get Gateway's Public Key

ServiceRadar needs the gateway's public key to verify JWT signatures.

### Option A: JWKS URL (Recommended)

Most gateways expose a JWKS (JSON Web Key Set) endpoint:

| Gateway | JWKS URL Pattern |
|---------|------------------|
| Kong | `https://gateway/.well-known/jwks.json` |
| Auth0 | `https://tenant.auth0.com/.well-known/jwks.json` |
| Okta | `https://org.okta.com/oauth2/default/v1/keys` |
| Google IAP | `https://www.gstatic.com/iap/verify/public_key-jwk` |
| AWS Cognito | `https://cognito-idp.{region}.amazonaws.com/{userPoolId}/.well-known/jwks.json` |

### Option B: PEM Public Key

If your gateway uses a static key pair:

```bash
# Extract public key from certificate
openssl x509 -in gateway-cert.pem -pubkey -noout > gateway-public.pem
```

## Step 3: Configure ServiceRadar

1. Log in to ServiceRadar as an admin
2. Navigate to **Settings** → **Authentication**
3. Select **Mode**: "Gateway/Proxy JWT"
4. Configure the following:

| Field | Description | Example |
|-------|-------------|---------|
| **JWT Header Name** | Header containing the JWT | `X-Auth-Token` or `Authorization` |
| **JWKS URL** | URL to gateway's public keys | `https://gateway/.well-known/jwks.json` |
| **— OR —** | | |
| **Public Key (PEM)** | Gateway's RSA/EC public key | `-----BEGIN PUBLIC KEY-----...` |
| **Expected Issuer** | `iss` claim value to validate | `https://gateway.example.com` |
| **Expected Audience** | `aud` claim value to validate | `serviceradar` |

5. Configure **Claim Mappings** for your gateway's JWT structure:

| ServiceRadar Field | Default Claim | Description |
|--------------------|---------------|-------------|
| Email | `email` | User's email address |
| Name | `name` | User's display name |
| Subject | `sub` | Unique user identifier |

6. Click **Test Gateway Configuration** to validate
7. If the test passes, toggle **Enable Authentication** to on
8. Click **Save**

## JWT Requirements

ServiceRadar expects the gateway JWT to include:

### Required Claims

| Claim | Description | Example |
|-------|-------------|---------|
| `sub` | Subject (unique user ID) | `user123` or `google-oauth2\|12345` |
| `email` | User's email address | `user@example.com` |
| `exp` | Expiration timestamp | `1735689600` |

### Recommended Claims

| Claim | Description | Example |
|-------|-------------|---------|
| `iss` | Issuer (your gateway) | `https://gateway.example.com` |
| `aud` | Audience (ServiceRadar) | `serviceradar` |
| `iat` | Issued at timestamp | `1735603200` |
| `name` | User's display name | `John Doe` |

### Example JWT Payload

```json
{
  "sub": "auth0|abc123",
  "email": "user@example.com",
  "name": "John Doe",
  "iss": "https://your-gateway.com",
  "aud": "serviceradar",
  "iat": 1735603200,
  "exp": 1735689600
}
```

## User Provisioning

ServiceRadar uses Just-In-Time (JIT) provisioning for gateway-authenticated users:

- **New users**: Automatically created on first request with `viewer` role
- **Existing users**: Matched by email and linked to their gateway identity
- **Session handling**: Each request with a valid JWT creates/refreshes the session

## Security Considerations

### JWT Signature Validation

ServiceRadar validates:
1. Signature using JWKS or configured public key
2. Supported algorithms: RS256, RS384, RS512, ES256, ES384, ES512
3. Key ID (`kid`) matching when using JWKS

### Claim Validation

ServiceRadar validates:
1. `iss` (issuer) matches configured expected issuer
2. `aud` (audience) matches configured expected audience
3. `exp` (expiration) is in the future
4. `iat` (issued at) is not too far in the future

### Network Security

Since ServiceRadar trusts the gateway JWT:

1. **Ensure ServiceRadar is not directly accessible** - Only the gateway should reach it
2. **Use network policies** - Restrict ingress to only the gateway
3. **Enable TLS** - Between gateway and ServiceRadar

Example Kubernetes NetworkPolicy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: serviceradar-ingress
spec:
  podSelector:
    matchLabels:
      app: serviceradar
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: gateway
      ports:
        - port: 4000
```

### JWKS Caching

JWKS responses are cached for 1 hour to reduce latency. The cache is automatically refreshed when:
- Cache expires
- Key ID not found in cache (triggers refresh)
- Admin manually refreshes configuration

## UI Behavior in Gateway Mode

When gateway authentication is enabled:

- Login page shows "Authentication via gateway required"
- No password form is displayed
- Users must access ServiceRadar through the gateway
- Direct access to ServiceRadar returns an authentication error

### Admin Backdoor

For emergency access when the gateway is unavailable:

1. Navigate to `/auth/local`
2. Log in with local admin credentials
3. Rate-limited to 5 attempts per minute

## Troubleshooting

### Common Issues

**"Invalid signature" errors:**
- Verify JWKS URL is accessible from ServiceRadar
- Check that the key ID (`kid`) in the JWT matches a key in JWKS
- Ensure the correct algorithm is being used

**"Invalid issuer" errors:**
- Check the `iss` claim matches the configured expected issuer exactly
- Include or exclude trailing slashes consistently

**"Invalid audience" errors:**
- Check the `aud` claim matches the configured expected audience
- Some IdPs send audience as an array

**Users not being created:**
- Verify the `email` claim is present in the JWT
- Check claim mappings match your gateway's JWT structure

### Debugging

Enable debug logging to see JWT validation details:

```elixir
# In config/runtime.exs
config :logger, level: :debug
```

Check logs for:
```
[debug] Gateway JWT validation: claims=...
[debug] Gateway JWT JWKS fetch: url=...
```

## Next Steps

- Configure [OIDC SSO](./sso-oidc-setup.md) for direct IdP integration
- Set up [API Credentials](./api-credentials.md) for programmatic access
- Review the [SSO Troubleshooting Guide](./sso-troubleshooting.md)
