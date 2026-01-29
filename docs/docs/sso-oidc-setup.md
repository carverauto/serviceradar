---
sidebar_position: 11
title: OIDC SSO Setup
---

# OpenID Connect (OIDC) SSO Setup

This guide explains how to configure ServiceRadar to use OpenID Connect for Single Sign-On authentication with identity providers like Google Workspace, Azure AD/Entra ID, Okta, Auth0, or Keycloak.

## Prerequisites

- Admin access to ServiceRadar
- Admin access to your Identity Provider (IdP)
- Your IdP must support OIDC with the authorization code flow

## Overview

OIDC authentication flow:

1. User clicks "Sign in with SSO" on the login page
2. User is redirected to your IdP for authentication
3. After successful authentication, IdP redirects back to ServiceRadar
4. ServiceRadar validates the ID token and creates/updates the user (JIT provisioning)
5. User is logged in with a ServiceRadar session

## Step 1: Register ServiceRadar with Your IdP

### Google Workspace

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Navigate to **APIs & Services** → **Credentials**
4. Click **Create Credentials** → **OAuth client ID**
5. Select **Web application** as the application type
6. Configure the following:
   - **Name**: ServiceRadar
   - **Authorized redirect URIs**: `https://your-serviceradar-domain.com/auth/oidc/callback`
7. Save and note the **Client ID** and **Client Secret**

**Discovery URL**: `https://accounts.google.com`

### Azure AD / Entra ID

1. Go to [Azure Portal](https://portal.azure.com/)
2. Navigate to **Azure Active Directory** → **App registrations**
3. Click **New registration**
4. Configure:
   - **Name**: ServiceRadar
   - **Supported account types**: Choose based on your needs
   - **Redirect URI**: Web - `https://your-serviceradar-domain.com/auth/oidc/callback`
5. After creation, go to **Certificates & secrets**
6. Create a new client secret and note the value
7. Note the **Application (client) ID** from the Overview page

**Discovery URL**: `https://login.microsoftonline.com/{tenant-id}/v2.0`

### Okta

1. Log in to your Okta Admin Console
2. Navigate to **Applications** → **Create App Integration**
3. Select **OIDC - OpenID Connect** and **Web Application**
4. Configure:
   - **App integration name**: ServiceRadar
   - **Grant type**: Authorization Code
   - **Sign-in redirect URIs**: `https://your-serviceradar-domain.com/auth/oidc/callback`
   - **Sign-out redirect URIs**: `https://your-serviceradar-domain.com/`
5. Save and note the **Client ID** and **Client Secret**

**Discovery URL**: `https://your-okta-domain.okta.com`

### Auth0

1. Log in to your Auth0 Dashboard
2. Navigate to **Applications** → **Create Application**
3. Select **Regular Web Applications**
4. Configure:
   - **Name**: ServiceRadar
   - **Allowed Callback URLs**: `https://your-serviceradar-domain.com/auth/oidc/callback`
   - **Allowed Logout URLs**: `https://your-serviceradar-domain.com/`
5. Note the **Client ID** and **Client Secret** from Settings

**Discovery URL**: `https://your-tenant.auth0.com`

### Keycloak

1. Log in to your Keycloak Admin Console
2. Select or create a realm
3. Navigate to **Clients** → **Create**
4. Configure:
   - **Client ID**: serviceradar
   - **Client Protocol**: openid-connect
   - **Access Type**: confidential
   - **Valid Redirect URIs**: `https://your-serviceradar-domain.com/auth/oidc/callback`
5. Go to **Credentials** tab and note the **Secret**

**Discovery URL**: `https://your-keycloak-domain/realms/{realm-name}`

## Step 2: Configure ServiceRadar

1. Log in to ServiceRadar as an admin
2. Navigate to **Settings** → **Authentication**
3. Select **Mode**: "Direct SSO (OIDC/SAML)"
4. Select **Provider Type**: "OIDC"
5. Fill in the configuration:

| Field | Description | Example |
|-------|-------------|---------|
| **Discovery URL** | Your IdP's OIDC discovery endpoint | `https://accounts.google.com` |
| **Client ID** | OAuth client ID from your IdP | `123456.apps.googleusercontent.com` |
| **Client Secret** | OAuth client secret from your IdP | `GOCSPX-xxxxx` |
| **Scopes** | OIDC scopes to request | `openid email profile` |

6. Configure **Claim Mappings** if your IdP uses non-standard claim names:

| ServiceRadar Field | Default Claim | Description |
|--------------------|---------------|-------------|
| Email | `email` | User's email address |
| Name | `name` | User's display name |
| Subject | `sub` | Unique user identifier |

7. Click **Test OIDC Configuration** to validate connectivity
8. If the test passes, toggle **Enable Authentication** to on
9. Click **Save**

## Step 3: Test SSO Login

1. Open a new incognito/private browser window
2. Navigate to your ServiceRadar login page
3. Click **Sign in with SSO**
4. You should be redirected to your IdP
5. Authenticate with your IdP credentials
6. You should be redirected back to ServiceRadar and logged in

## User Provisioning

ServiceRadar uses Just-In-Time (JIT) provisioning for SSO users:

- **New users**: Automatically created on first SSO login with `viewer` role
- **Existing users**: Matched by email address and linked to their SSO identity
- **User attributes**: Display name is synced from the IdP on each login

### Assigning Roles

SSO-provisioned users are created with the `viewer` role by default. Admins can promote users to higher roles:

1. Navigate to **Settings** → **Users**
2. Find the user and click **Edit**
3. Change the **Role** to `operator` or `admin`
4. Click **Save**

## Security Considerations

### State Parameter (CSRF Protection)

ServiceRadar generates a cryptographically random `state` parameter for each OIDC flow to prevent cross-site request forgery attacks. This is handled automatically.

### Nonce Validation

A `nonce` is included in the authorization request and validated in the ID token to prevent replay attacks.

### Token Validation

ServiceRadar validates ID tokens by:
1. Verifying the signature using the IdP's JWKS
2. Checking the `iss` (issuer) matches the discovery document
3. Checking the `aud` (audience) matches your client ID
4. Ensuring the token hasn't expired

### Rate Limiting

SSO callback endpoints are rate-limited to 20 requests per minute per IP address to prevent abuse.

## Fallback Authentication

When SSO is enabled, password authentication is still available for:

- **Admin backdoor**: Navigate to `/auth/local` for local admin login
- **API authentication**: API tokens still work for programmatic access

This ensures you can always access ServiceRadar even if your IdP is unavailable.

## Troubleshooting

See the [SSO Troubleshooting Guide](./sso-troubleshooting.md) for common issues and solutions.

## Next Steps

- Configure [SAML SSO](./sso-saml-setup.md) as an alternative to OIDC
- Set up [API Credentials](./api-credentials.md) for programmatic access
- Review the [Security Architecture](./security-architecture.md)
