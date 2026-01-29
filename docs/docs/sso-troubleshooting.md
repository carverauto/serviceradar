---
sidebar_position: 15
title: SSO Troubleshooting
---

# SSO Troubleshooting Guide

This guide helps diagnose and resolve common issues with Single Sign-On authentication in ServiceRadar.

## Quick Diagnostics

Before diving into specific issues, gather this information:

1. **Authentication mode**: OIDC, SAML, or Gateway?
2. **Error message**: Exact error shown to user
3. **Browser console**: Any JavaScript errors?
4. **Server logs**: Check ServiceRadar logs for details
5. **IdP logs**: Check your identity provider's audit logs

### Accessing Logs

```bash
# Docker
docker logs serviceradar-web-ng

# Kubernetes
kubectl logs -l app=serviceradar-web-ng

# Systemd
journalctl -u serviceradar-web-ng
```

## OIDC Issues

### "OIDC configuration error"

**Symptoms:**
- Error when clicking "Sign in with SSO"
- Message: "SSO configuration error. Please contact your administrator."

**Causes & Solutions:**

1. **Invalid discovery URL**
   ```
   Check: Can you access the discovery URL?
   curl https://your-idp/.well-known/openid-configuration
   ```
   - Ensure the URL is correct and accessible from ServiceRadar
   - Check for typos (trailing slashes, https vs http)

2. **Discovery endpoint unreachable**
   - Check network connectivity from ServiceRadar to IdP
   - Verify firewall rules allow outbound HTTPS
   - Check if IdP requires IP allowlisting

3. **Invalid client credentials**
   - Verify client ID and secret in ServiceRadar settings
   - Regenerate credentials in your IdP if needed

### "Authentication failed: invalid state"

**Symptoms:**
- Redirected back to login with state error
- Error after successful IdP authentication

**Causes & Solutions:**

1. **Session cookie issues**
   - Clear browser cookies and try again
   - Check if third-party cookies are blocked
   - Ensure ServiceRadar uses secure cookies over HTTPS

2. **Multiple tabs/windows**
   - Close all ServiceRadar tabs except one
   - Start a fresh authentication flow

3. **Browser back button**
   - Don't use back button during SSO flow
   - Start from the login page again

4. **Session timeout**
   - The SSO flow took too long
   - Try again immediately after clicking SSO button

### "Invalid issuer" or "Invalid audience"

**Symptoms:**
- Error after IdP authentication
- Token validation failure in logs

**Causes & Solutions:**

1. **Issuer mismatch**
   ```
   Expected: https://accounts.google.com
   Received: https://accounts.google.com/
   ```
   - Check exact issuer value in IdP's discovery document
   - Match exactly, including trailing slashes

2. **Audience mismatch**
   - Verify client ID in ServiceRadar matches IdP configuration
   - Some IdPs require audience to be set explicitly

3. **Multi-tenant Azure AD**
   - Use tenant-specific endpoint, not common endpoint
   - `https://login.microsoftonline.com/{tenant-id}/v2.0`

### "Invalid nonce"

**Symptoms:**
- Authentication fails on callback
- Nonce validation error in logs

**Causes & Solutions:**

1. **Replay attack protection triggered**
   - Each SSO attempt needs a fresh start
   - Don't bookmark or share SSO callback URLs

2. **Session state lost**
   - Check session storage configuration
   - Verify cookies are not being cleared

### "Token expired"

**Symptoms:**
- Works initially, then fails
- Error after IdP token expires

**Causes & Solutions:**

1. **Clock skew**
   - Ensure ServiceRadar server time is synchronized
   - Use NTP to keep clocks accurate
   ```bash
   timedatectl status
   ```

2. **Very short token lifetime**
   - Adjust token lifetime in IdP settings
   - Minimum recommended: 5 minutes

## SAML Issues

### "No IdP metadata"

**Symptoms:**
- SAML configuration test fails
- Error when attempting SSO

**Causes & Solutions:**

1. **Metadata URL unreachable**
   ```bash
   curl https://your-idp/metadata
   ```
   - Check URL is correct and accessible
   - Some IdPs require authentication to access metadata

2. **Invalid metadata XML**
   - Download metadata and validate XML structure
   - Check for encoding issues (UTF-8 BOM)

3. **Expired IdP certificate**
   - Check certificate validity in metadata
   - Request updated metadata from IdP admin

### "Signature validation failed"

**Symptoms:**
- Error after IdP authentication
- SAML response rejected

**Causes & Solutions:**

1. **Certificate mismatch**
   - IdP certificate was rotated
   - Re-fetch metadata from IdP
   - Clear metadata cache: refresh configuration

2. **Certificate pinning rejection**
   - If using certificate pinning, update pinned fingerprints
   - Get new fingerprint:
   ```bash
   openssl x509 -in idp-cert.pem -noout -fingerprint -sha256
   ```

3. **Assertion not signed**
   - Configure IdP to sign assertions (not just response)
   - Check IdP signing settings

4. **Wrong certificate in metadata**
   - Some IdPs have multiple certificates
   - Ensure signing certificate is included

### "ACS URL mismatch"

**Symptoms:**
- IdP rejects authentication request
- Error about invalid recipient or destination

**Causes & Solutions:**

1. **URL mismatch in IdP configuration**
   - ACS URL must match exactly:
   ```
   https://your-serviceradar.com/auth/saml/consume
   ```
   - Check for http vs https
   - Check for trailing slashes

2. **Load balancer URL rewriting**
   - Configure IdP with external URL, not internal
   - Ensure X-Forwarded headers are passed correctly

### "NameID not found"

**Symptoms:**
- User creation fails
- Missing email in SAML assertion

**Causes & Solutions:**

1. **Wrong NameID format**
   - Configure IdP to use email as NameID
   - Or map email from assertion attributes

2. **Missing attribute release**
   - Configure IdP to release email attribute
   - Check attribute mapping in ServiceRadar

3. **Attribute name mismatch**
   - Check actual attribute names in SAML assertion
   - Update claim mappings in ServiceRadar

### Debugging SAML Assertions

Use a SAML decoder to inspect assertions:

1. Capture the SAMLResponse from browser network tab
2. Base64 decode and decompress (if deflated)
3. Check:
   - Subject/NameID value
   - Attribute names and values
   - Signature present and valid
   - NotBefore/NotOnOrAfter timestamps

Online tools: https://samltool.io, https://www.samltool.com/decode.php

## Gateway Authentication Issues

### "Invalid signature"

**Symptoms:**
- All requests rejected
- Signature verification fails

**Causes & Solutions:**

1. **Wrong public key or JWKS**
   - Verify JWKS URL returns valid keys
   - Check key ID (kid) matches JWT header
   ```bash
   curl https://gateway/.well-known/jwks.json | jq
   ```

2. **Algorithm mismatch**
   - Check JWT `alg` header matches expected
   - Ensure ServiceRadar supports the algorithm

3. **Key rotation**
   - Gateway rotated keys
   - Clear JWKS cache: refresh configuration
   - Verify new keys are in JWKS

### "JWT header not found"

**Symptoms:**
- Authentication fails for all users
- No token reaching ServiceRadar

**Causes & Solutions:**

1. **Wrong header name**
   - Check configured header name matches gateway
   - Common headers: `Authorization`, `X-Auth-Token`

2. **Header stripped by proxy**
   - Check intermediate proxies aren't removing headers
   - Verify gateway is actually adding the header

3. **Case sensitivity**
   - HTTP headers are case-insensitive
   - But check configuration matches

### "Invalid issuer/audience"

**Symptoms:**
- Token signature valid but claims rejected

**Causes & Solutions:**

1. **Issuer mismatch**
   - Check exact `iss` claim in JWT
   - Match in ServiceRadar configuration

2. **Audience mismatch**
   - Check `aud` claim (may be array)
   - Configure expected audience correctly

### Users Not Being Created

**Symptoms:**
- Authentication succeeds but session not created
- User not found errors

**Causes & Solutions:**

1. **Missing email claim**
   - JWT must contain email
   - Check claim mapping configuration

2. **Invalid email format**
   - Email must be valid format
   - Check for encoding issues

## General Issues

### Rate Limiting

**Symptoms:**
- "Too many authentication attempts"
- 429 responses

**Causes & Solutions:**

- Wait for rate limit window to reset (60 seconds)
- Check for authentication loops causing rapid requests
- Review integration code for excessive token requests

### Admin Lockout

If you're locked out of ServiceRadar:

1. **Use local admin backdoor**
   - Navigate to `/auth/local`
   - Log in with local admin credentials
   - Rate limited to 5 attempts per minute

2. **Reset via environment**
   ```bash
   # Set bootstrap admin credentials
   export ADMIN_EMAIL="admin@example.com"
   export ADMIN_PASSWORD="new-secure-password"
   # Restart ServiceRadar
   ```

3. **Disable SSO via database** (emergency only)
   ```sql
   UPDATE platform.auth_settings SET is_enabled = false;
   ```

### Session Issues

**Symptoms:**
- Logged out unexpectedly
- Session not persisting

**Causes & Solutions:**

1. **Cookie settings**
   - Check secure cookie configuration
   - Verify domain matches

2. **Token revocation**
   - Password change revokes all tokens
   - Admin may have revoked sessions

3. **Clock skew**
   - Synchronize server time with NTP

## Collecting Debug Information

When contacting support, provide:

1. **ServiceRadar version**
   ```bash
   docker inspect serviceradar-web-ng | grep Image
   ```

2. **Configuration** (redact secrets)
   - Authentication mode
   - Provider type
   - Discovery URL (OIDC) or Metadata URL (SAML)

3. **Error details**
   - Exact error message
   - Timestamp
   - User email (if known)

4. **Server logs**
   ```bash
   # Last 100 lines with auth errors
   docker logs serviceradar-web-ng 2>&1 | grep -i "auth\|error" | tail -100
   ```

5. **Browser information**
   - Browser and version
   - Network tab screenshots
   - Console errors

## Health Checks

### OIDC Health Check

```bash
# Test discovery endpoint
curl -s https://your-idp/.well-known/openid-configuration | jq '.issuer'

# Test JWKS endpoint
curl -s https://your-idp/.well-known/jwks.json | jq '.keys | length'
```

### SAML Health Check

```bash
# Test metadata endpoint
curl -s https://your-idp/metadata | head -20

# Validate metadata XML
curl -s https://your-idp/metadata | xmllint --noout -
```

### Gateway Health Check

```bash
# Test JWKS endpoint
curl -s https://gateway/.well-known/jwks.json | jq '.keys[0].kid'

# Decode a JWT (without verification)
echo "eyJ..." | cut -d. -f2 | base64 -d 2>/dev/null | jq
```

## Getting Help

If you're still stuck:

1. Check [ServiceRadar GitHub Issues](https://github.com/serviceradar/serviceradar/issues)
2. Search existing issues for similar problems
3. Open a new issue with debug information collected above
