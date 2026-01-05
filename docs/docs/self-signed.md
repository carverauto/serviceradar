---
sidebar_position: 12
title: SSL Configuration for Caddy
---

# SSL Configuration for Caddy

ServiceRadar supports secure HTTPS connections through Caddy with SSL certificates. This guide explains how to configure Caddy to use SSL certificates for securing your ServiceRadar web interface.

## Overview

Securing your ServiceRadar web interface with HTTPS provides:
- Encrypted communication between browsers and your ServiceRadar instance
- Protection of sensitive monitoring data and authentication credentials
- Prevention of man-in-the-middle attacks
- Browser security indicators showing the connection is secure

While production environments should ideally use certificates from trusted certificate authorities, self-signed certificates are suitable for internal deployments, testing environments, or scenarios where trusted certificates aren't practical.

## Prerequisites

- ServiceRadar with Web UI and Caddy installed
- Root or sudo access to the server
- SSL certificates (self-signed or from a certificate authority)

## Certificate Generation

ServiceRadar already provides comprehensive instructions for generating certificates in the [TLS Security](./tls-security.md) documentation. You can use those same certificates for securing your Caddy configuration.

If you've already generated certificates for other ServiceRadar components using the instructions in the TLS Security section, you can reuse them for Caddy. Otherwise, follow those instructions to generate your certificates first, then return to this guide to configure Caddy.

Alternatively, you can generate a simple self-signed certificate using OpenSSL:

```bash
# Create directory for certificates if not exists
sudo mkdir -p /etc/ssl/certs /etc/ssl/private

# Generate private key
sudo openssl genrsa -out /etc/ssl/private/serviceradar.key 2048

# Generate certificate signing request (CSR)
sudo openssl req -new -key /etc/ssl/private/serviceradar.key -out /etc/ssl/certs/serviceradar.csr

# Generate self-signed certificate valid for 365 days
sudo openssl x509 -req -days 365 -in /etc/ssl/certs/serviceradar.csr \
    -signkey /etc/ssl/private/serviceradar.key \
    -out /etc/ssl/certs/serviceradar.crt

# Set proper permissions
sudo chmod 600 /etc/ssl/private/serviceradar.key
sudo chmod 644 /etc/ssl/certs/serviceradar.crt
```

When generating the CSR, you'll be prompted for information like country, state, organization, and common name. For the Common Name (CN), enter your server's domain name (e.g., `serviceradar.example.com`).

## Installing Certificates

Once you have your certificates, install them in the appropriate location:

```bash
sudo mkdir -p /etc/ssl/certs /etc/ssl/private
sudo mv web.pem /etc/ssl/certs/
sudo mv web-key.pem /etc/ssl/private/
sudo chmod 644 /etc/ssl/certs/web.pem
sudo chmod 600 /etc/ssl/private/web-key.pem
```

## Configuring Caddy for SSL

Update your Caddy configuration to use SSL:

1. Edit or create the ServiceRadar Caddyfile:

```bash
sudo nano /etc/caddy/Caddyfile
```

2. Replace the content with the following configuration:

```caddy
https://serviceradar.example.com {
  tls /etc/ssl/certs/web.pem /etc/ssl/private/web-key.pem
  reverse_proxy 127.0.0.1:4000
}
```

Replace `serviceradar.example.com` with your actual domain name and remove or replace `serviceradar` with your actual hostname if different.

3. Validate the Caddy configuration:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
```

4. If the validation is successful, reload Caddy:

```bash
sudo systemctl reload caddy
```

## Firewall Configuration

If you're using a firewall, ensure that port 443 (HTTPS) is open:

```bash
# For UFW (Ubuntu)
sudo ufw allow 443/tcp

# For firewalld (RHEL/Oracle Linux)
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

## Browser Security Warnings

When using self-signed certificates, browsers will display security warnings because the certificate isn't issued by a trusted certificate authority. This is normal and expected.

To proceed to your ServiceRadar instance:
- In Chrome: Click "Advanced" and then "Proceed to [site] (unsafe)"
- In Firefox: Click "Advanced" > "Accept the Risk and Continue"
- In Edge: Click "Details" > "Go on to the webpage (not recommended)"

For production environments, consider obtaining a certificate from a trusted certificate authority like Let's Encrypt.

## Using Let's Encrypt (For Production)

For public-facing ServiceRadar instances, Caddy can automatically obtain and renew Let's Encrypt certificates when you specify a public domain in the Caddyfile:

```caddy
https://your-domain.com {
  reverse_proxy 127.0.0.1:4000
}
```

No separate certbot workflow is required when Caddy is managing TLS.

## Troubleshooting

### Certificate Problems

If you encounter certificate-related issues:

1. Verify certificate permissions:
```bash
ls -la /etc/ssl/certs/web.pem
ls -la /etc/ssl/private/web-key.pem
```

2. Check certificate details:
```bash
openssl x509 -in /etc/ssl/certs/web.pem -text -noout
```

3. Verify that the hostname in the certificate matches your server's hostname.

### Caddy Configuration Issues

If Caddy fails to start:

1. Check the Caddy logs:
```bash
sudo journalctl -xeu caddy
```

2. Verify the Caddy configuration:
```bash
sudo caddy validate --config /etc/caddy/Caddyfile
```

3. Ensure the certificate paths in the Caddyfile match the actual paths.

## Next Steps

- Configure [Authentication](./auth-configuration.md) for your secure ServiceRadar instance
- Set up [CORS Configuration](./auth-configuration.md#cors-configuration) to control API access
- Learn about [ServiceRadar Architecture](./architecture.md)
