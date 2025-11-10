---
sidebar_position: 12
title: SSL Configuration for Nginx
---

# SSL Configuration for Nginx

ServiceRadar supports secure HTTPS connections through Nginx with SSL certificates. This guide explains how to configure Nginx to use SSL certificates for securing your ServiceRadar web interface.

## Overview

Securing your ServiceRadar web interface with HTTPS provides:
- Encrypted communication between browsers and your ServiceRadar instance
- Protection of sensitive monitoring data and authentication credentials
- Prevention of man-in-the-middle attacks
- Browser security indicators showing the connection is secure

While production environments should ideally use certificates from trusted certificate authorities, self-signed certificates are suitable for internal deployments, testing environments, or scenarios where trusted certificates aren't practical.

## Prerequisites

- ServiceRadar with Web UI and Nginx installed
- Root or sudo access to the server
- SSL certificates (self-signed or from a certificate authority)

## Certificate Generation

ServiceRadar already provides comprehensive instructions for generating certificates in the [TLS Security](./tls-security.md) documentation. You can use those same certificates for securing your Nginx configuration.

If you've already generated certificates for other ServiceRadar components using the instructions in the TLS Security section, you can reuse them for Nginx. Otherwise, follow those instructions to generate your certificates first, then return to this guide to configure Nginx.

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

## Configuring Nginx for SSL

Update your Nginx configuration to use SSL:

1. Edit or create the ServiceRadar Nginx configuration file:

```bash
sudo nano /etc/nginx/conf.d/serviceradar-web.conf
```

2. Replace the content with the following configuration:

```nginx
# ServiceRadar Web Interface - Nginx Configuration
# HTTPS Server Block
server {
    listen 443 ssl;
    server_name serviceradar.example.com serviceradar;
    
    # Paths to your self-signed certificate and key
    ssl_certificate /etc/ssl/certs/web.pem;
    ssl_certificate_key /etc/ssl/private/web-key.pem;
    
    # SSL security settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    
    # Static assets
    location /_next/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # API routes handled by Next.js
    location ~ ^/api/(auth|pollers|status|config) {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # Backend API routes (protected by Kong)
    location /api/ {
        # Kong should be running locally (standalone or native)
        proxy_pass http://127.0.0.1:9080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # Auth API routes
    location /auth/ {
        proxy_pass http://localhost:8090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization, X-API-Key" always;
    }
    
    # Main app
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# HTTP Server Block (Redirect to HTTPS)
server {
    listen 80;
    server_name serviceradar.example.com serviceradar;
    return 301 https://$host$request_uri;
}
```

Replace `serviceradar.example.com` with your actual domain name and remove or replace `serviceradar` with your actual hostname if different.

3. Test the Nginx configuration:

```bash
sudo nginx -t
```

4. If the test is successful, restart Nginx:

```bash
sudo systemctl restart nginx
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

For public-facing ServiceRadar instances, Let's Encrypt provides free, trusted certificates:

```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx

# Obtain and install certificate
sudo certbot --nginx -d serviceradar.example.com

# Certificate renewal will be handled automatically by a systemd timer
```

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

### Nginx Configuration Issues

If Nginx fails to start:

1. Check the Nginx error log:
```bash
sudo tail -f /var/log/nginx/error.log
```

2. Verify the Nginx configuration:
```bash
sudo nginx -t
```

3. Ensure the certificate paths in the Nginx configuration match the actual paths.

## Next Steps

- Configure [Authentication](./auth-configuration.md) for your secure ServiceRadar instance
- Set up [CORS Configuration](./auth-configuration.md#cors-configuration) to control API access
- Learn about [ServiceRadar Architecture](./architecture.md)
