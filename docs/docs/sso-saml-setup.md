---
sidebar_position: 12
title: SAML SSO Setup
---

# SAML 2.0 SSO Setup

This guide explains how to configure ServiceRadar to use SAML 2.0 for Single Sign-On authentication with identity providers like Okta, Azure AD/Entra ID, OneLogin, or PingFederate.

## Prerequisites

- Admin access to ServiceRadar
- Admin access to your SAML Identity Provider (IdP)
- Your IdP must support SAML 2.0 with HTTP-POST binding

## Overview

SAML authentication flow:

1. User clicks "Sign in with SSO" on the login page
2. ServiceRadar generates a SAML AuthnRequest and redirects to your IdP
3. User authenticates with the IdP
4. IdP sends a SAML Response (assertion) back to ServiceRadar
5. ServiceRadar validates the assertion signature and creates/updates the user
6. User is logged in with a ServiceRadar session

## ServiceRadar SP Information

Before configuring your IdP, note these ServiceRadar Service Provider (SP) details:

| Field | Value |
|-------|-------|
| **Entity ID (SP)** | `https://your-serviceradar-domain.com` |
| **ACS URL** | `https://your-serviceradar-domain.com/auth/saml/consume` |
| **Metadata URL** | `https://your-serviceradar-domain.com/auth/saml/metadata` |
| **Name ID Format** | `urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress` |

## Step 1: Configure Your IdP

### Okta

1. Log in to your Okta Admin Console
2. Navigate to **Applications** → **Create App Integration**
3. Select **SAML 2.0**
4. Configure General Settings:
   - **App name**: ServiceRadar
5. Configure SAML Settings:
   - **Single sign on URL**: `https://your-serviceradar-domain.com/auth/saml/consume`
   - **Audience URI (SP Entity ID)**: `https://your-serviceradar-domain.com`
   - **Name ID format**: EmailAddress
   - **Application username**: Email
6. Configure Attribute Statements:
   | Name | Value |
   |------|-------|
   | `email` | `user.email` |
   | `name` | `user.displayName` |
   | `firstName` | `user.firstName` |
   | `lastName` | `user.lastName` |
7. Complete the wizard and note the **Metadata URL** from the Sign On tab

### Azure AD / Entra ID

1. Go to [Azure Portal](https://portal.azure.com/)
2. Navigate to **Azure Active Directory** → **Enterprise applications**
3. Click **New application** → **Create your own application**
4. Select "Integrate any other application you don't find in the gallery (Non-gallery)"
5. After creation, go to **Single sign-on** → **SAML**
6. Configure Basic SAML Configuration:
   - **Identifier (Entity ID)**: `https://your-serviceradar-domain.com`
   - **Reply URL (ACS URL)**: `https://your-serviceradar-domain.com/auth/saml/consume`
7. Configure Attributes & Claims:
   | Claim name | Source attribute |
   |------------|------------------|
   | `emailaddress` | `user.mail` |
   | `name` | `user.displayname` |
8. Download the **Federation Metadata XML** from SAML Certificates section

### OneLogin

1. Log in to your OneLogin Admin Console
2. Navigate to **Applications** → **Add App**
3. Search for "SAML Custom Connector (Advanced)"
4. Configure:
   - **Display Name**: ServiceRadar
   - **Audience (Entity ID)**: `https://your-serviceradar-domain.com`
   - **Recipient**: `https://your-serviceradar-domain.com/auth/saml/consume`
   - **ACS URL**: `https://your-serviceradar-domain.com/auth/saml/consume`
   - **SAML nameID format**: Email
5. Configure Parameters:
   | Field Name | Value |
   |------------|-------|
   | `email` | Email |
   | `name` | First Name + Last Name |
6. Save and note the **Issuer URL** for metadata

### PingFederate

1. Log in to PingFederate Admin Console
2. Navigate to **SP Connections** → **Create New**
3. Configure Connection Type: Browser SSO Profiles (SAML 2.0)
4. Configure:
   - **Partner's Entity ID**: `https://your-serviceradar-domain.com`
   - **Connection Name**: ServiceRadar
5. Configure Browser SSO:
   - **Assertion Consumer Service URL**: `https://your-serviceradar-domain.com/auth/saml/consume`
   - **Binding**: HTTP POST
6. Configure Attribute Contract with email and name attributes
7. Export the IdP metadata

## Step 2: Configure ServiceRadar

1. Log in to ServiceRadar as an admin
2. Navigate to **Settings** → **Authentication**
3. Select **Mode**: "Direct SSO (OIDC/SAML)"
4. Select **Provider Type**: "SAML"
5. Configure IdP Metadata (choose one method):

### Option A: Metadata URL (Recommended)

If your IdP provides a metadata URL:

| Field | Description | Example |
|-------|-------------|---------|
| **IdP Metadata URL** | URL to your IdP's metadata | `https://idp.example.com/metadata` |

### Option B: Metadata XML

If your IdP provides a downloadable XML file:

1. Download the metadata XML from your IdP
2. Copy the entire XML content
3. Paste it into the **IdP Metadata XML** field

6. Configure **Claim Mappings** if your IdP uses non-standard attribute names:

| ServiceRadar Field | Default Attribute | Description |
|--------------------|-------------------|-------------|
| Email | `email` or `emailaddress` | User's email address |
| Name | `name` or `displayname` | User's display name |
| Subject | `sub` or NameID | Unique user identifier |

7. (Optional) Configure **Certificate Pinning** for enhanced security:
   - Enter SHA256 fingerprints of trusted IdP certificates
   - Format: `AA:BB:CC:DD:...` (hex pairs separated by colons)

8. Click **Test SAML Configuration** to validate
9. If the test passes, toggle **Enable Authentication** to on
10. Click **Save**

## Step 3: Assign Users in Your IdP

Most IdPs require you to assign users or groups to the application:

### Okta
- Go to **Assignments** tab and assign users/groups

### Azure AD
- Go to **Users and groups** and add assignments

### OneLogin
- Go to **Users** tab and assign access

## Step 4: Test SSO Login

1. Open a new incognito/private browser window
2. Navigate to your ServiceRadar login page
3. Click **Sign in with SSO**
4. You should be redirected to your IdP
5. Authenticate with your IdP credentials
6. You should be redirected back to ServiceRadar and logged in

## User Provisioning

ServiceRadar uses Just-In-Time (JIT) provisioning for SAML users:

- **New users**: Automatically created on first SSO login with `viewer` role
- **Existing users**: Matched by email address and linked to their SAML identity
- **User attributes**: Display name is synced from SAML assertions on each login

## Security Considerations

### Assertion Signature Validation

ServiceRadar validates SAML assertion signatures using:
1. The public key from the IdP metadata
2. XML Signature validation (XML-DSig)
3. Certificate trust chain verification

### Certificate Pinning (Optional)

For enhanced security, you can pin specific IdP certificates:

1. Get the SHA256 fingerprint of your IdP's signing certificate:
   ```bash
   openssl x509 -in idp-cert.pem -noout -fingerprint -sha256
   ```
2. Enter the fingerprint in the Certificate Pinning field
3. Only assertions signed by pinned certificates will be accepted

### RelayState CSRF Protection

ServiceRadar generates a cryptographically random RelayState token for each SAML flow to prevent cross-site request forgery attacks.

### Rate Limiting

The SAML ACS endpoint is rate-limited to 20 requests per minute per IP address.

## Attribute Mapping Reference

Common attribute names used by different IdPs:

| Attribute | Okta | Azure AD | OneLogin | Standard |
|-----------|------|----------|----------|----------|
| Email | `email` | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress` | `email` | `email` |
| Name | `displayName` | `http://schemas.microsoft.com/identity/claims/displayname` | `name` | `name` |
| First Name | `firstName` | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname` | `first_name` | `givenName` |
| Last Name | `lastName` | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname` | `last_name` | `sn` |

Configure claim mappings in ServiceRadar to match your IdP's attribute names.

## SP Metadata

ServiceRadar can generate SP metadata for your IdP. Access it at:

```
https://your-serviceradar-domain.com/auth/saml/metadata
```

This XML file contains:
- SP Entity ID
- ACS URL with binding information
- Supported NameID formats
- (Optional) SP signing certificate

## Fallback Authentication

When SAML SSO is enabled, password authentication is still available:

- **Admin backdoor**: Navigate to `/auth/local` for local admin login
- **API authentication**: API tokens still work for programmatic access

## Troubleshooting

See the [SSO Troubleshooting Guide](./sso-troubleshooting.md) for common issues and solutions.

## Next Steps

- Configure [OIDC SSO](./sso-oidc-setup.md) as an alternative to SAML
- Set up [Gateway Authentication](./sso-gateway-setup.md) for proxy deployments
- Review the [Security Architecture](./security-architecture.md)
