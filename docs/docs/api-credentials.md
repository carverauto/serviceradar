---
sidebar_position: 14
title: API Credentials
---

# API Credentials

This guide explains how to create and use API credentials for programmatic access to the ServiceRadar API, enabling automation, integrations, and custom tooling.

## Overview

ServiceRadar supports OAuth 2.0 Client Credentials flow for API authentication:

1. Create an API client in the ServiceRadar UI
2. Use the client ID and secret to obtain an access token
3. Include the access token in API requests

This approach provides:
- **Secure authentication** without embedding user passwords
- **Scoped access** to limit what each client can do
- **Audit trail** of client usage
- **Easy revocation** when credentials are compromised

## Creating API Credentials

### Via Web UI

1. Log in to ServiceRadar
2. Navigate to **Settings** → **API Credentials**
3. Click **Create API Client**
4. Configure the client:

| Field | Description | Example |
|-------|-------------|---------|
| **Name** | Descriptive name for the client | `CI Pipeline`, `Monitoring Script` |
| **Description** | Optional details about usage | `Used by Jenkins for deployment checks` |
| **Scopes** | Permissions to grant | `read`, `read write` |

5. Click **Create**
6. **Important**: Copy the client secret immediately - it will only be shown once!

### Client Credentials Output

After creation, you'll receive:

```
Client ID:     a1b2c3d4-e5f6-7890-abcd-ef1234567890
Client Secret: sr_secret_xK9mN2pQ4rS6tU8vW0xY2zA4bC6dE8fG0hI2jK4lM6nO8pQ0rS2tU4vW6xY8zA0b
```

Store these securely - the secret cannot be retrieved later.

## Using API Credentials

### Step 1: Obtain Access Token

Request an access token using the client credentials:

```bash
curl -X POST https://your-serviceradar.com/oauth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=a1b2c3d4-e5f6-7890-abcd-ef1234567890" \
  -d "client_secret=sr_secret_xK9mN2pQ4rS6tU8vW0xY2zA4bC6dE8fG0hI2jK4lM6nO8pQ0rS2tU4vW6xY8zA0b"
```

Response:

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "read write"
}
```

### Step 2: Use Access Token

Include the token in the `Authorization` header:

```bash
curl https://your-serviceradar.com/api/v1/devices \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
```

## Token Lifetime and Refresh

- **Default expiration**: 1 hour
- **No refresh tokens**: Request a new token when expired
- **Automatic caching**: Cache tokens and reuse until near expiration

### Best Practice: Token Caching

```python
import time
import requests

class ServiceRadarClient:
    def __init__(self, client_id, client_secret, base_url):
        self.client_id = client_id
        self.client_secret = client_secret
        self.base_url = base_url
        self._token = None
        self._token_expires = 0

    def _get_token(self):
        # Return cached token if still valid (with 60s buffer)
        if self._token and time.time() < self._token_expires - 60:
            return self._token

        # Request new token
        response = requests.post(
            f"{self.base_url}/oauth/token",
            data={
                "grant_type": "client_credentials",
                "client_id": self.client_id,
                "client_secret": self.client_secret,
            }
        )
        response.raise_for_status()
        data = response.json()

        self._token = data["access_token"]
        self._token_expires = time.time() + data["expires_in"]
        return self._token

    def get(self, endpoint):
        response = requests.get(
            f"{self.base_url}{endpoint}",
            headers={"Authorization": f"Bearer {self._get_token()}"}
        )
        response.raise_for_status()
        return response.json()

# Usage
client = ServiceRadarClient(
    client_id="a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    client_secret="sr_secret_...",
    base_url="https://your-serviceradar.com"
)

devices = client.get("/api/v1/devices")
```

## Scopes

Scopes control what actions a client can perform:

| Scope | Description |
|-------|-------------|
| `read` | Read-only access to resources |
| `write` | Create and update resources |
| `delete` | Delete resources |
| `admin` | Administrative operations |

### Requesting Specific Scopes

You can request a subset of granted scopes when obtaining a token:

```bash
curl -X POST https://your-serviceradar.com/oauth/token \
  -d "grant_type=client_credentials" \
  -d "client_id=..." \
  -d "client_secret=..." \
  -d "scope=read"
```

This is useful for least-privilege access in specific integrations.

## Managing API Clients

### Viewing Clients

Navigate to **Settings** → **API Credentials** to see all your clients:

- Name and description
- Created date
- Last used timestamp
- Request count
- Assigned scopes

### Regenerating Secrets

If a client secret is compromised:

1. Go to **Settings** → **API Credentials**
2. Find the client and click **Regenerate Secret**
3. Update your integrations with the new secret
4. The old secret is immediately invalidated

### Revoking Clients

To revoke a client entirely:

1. Go to **Settings** → **API Credentials**
2. Find the client and click **Revoke**
3. Confirm the action
4. All tokens issued to this client become invalid immediately

## Security Best Practices

### Secret Management

1. **Never commit secrets to version control**
   ```bash
   # Use environment variables
   export SERVICERADAR_CLIENT_SECRET="sr_secret_..."
   ```

2. **Use secret management tools**
   - HashiCorp Vault
   - AWS Secrets Manager
   - Kubernetes Secrets
   - Azure Key Vault

3. **Rotate secrets periodically**
   - Regenerate secrets every 90 days
   - Immediately rotate if exposure is suspected

### Least Privilege

1. **Create separate clients** for different use cases
2. **Grant minimum required scopes** for each client
3. **Use read-only scope** for monitoring/reporting integrations

### Monitoring

1. **Review usage** in the API Credentials dashboard
2. **Set up alerts** for unusual activity patterns
3. **Audit access logs** periodically

## Common Integration Examples

### CI/CD Pipeline (GitHub Actions)

```yaml
name: Check ServiceRadar Status

on:
  schedule:
    - cron: '0 * * * *'

jobs:
  check-status:
    runs-on: ubuntu-latest
    steps:
      - name: Get ServiceRadar Token
        id: auth
        run: |
          TOKEN=$(curl -s -X POST ${{ secrets.SERVICERADAR_URL }}/oauth/token \
            -d "grant_type=client_credentials" \
            -d "client_id=${{ secrets.SERVICERADAR_CLIENT_ID }}" \
            -d "client_secret=${{ secrets.SERVICERADAR_CLIENT_SECRET }}" \
            | jq -r '.access_token')
          echo "token=$TOKEN" >> $GITHUB_OUTPUT

      - name: Check Device Status
        run: |
          curl -s ${{ secrets.SERVICERADAR_URL }}/api/v1/devices \
            -H "Authorization: Bearer ${{ steps.auth.outputs.token }}" \
            | jq '.data[] | select(.is_available == false)'
```

### Prometheus Exporter

```python
from prometheus_client import start_http_server, Gauge
import time

# Create metrics
device_count = Gauge('serviceradar_device_count', 'Number of devices')
unavailable_devices = Gauge('serviceradar_unavailable_devices', 'Unavailable devices')

def collect_metrics(client):
    devices = client.get("/api/v1/devices")["data"]
    device_count.set(len(devices))
    unavailable_devices.set(sum(1 for d in devices if not d.get("is_available")))

if __name__ == "__main__":
    client = ServiceRadarClient(...)
    start_http_server(8000)
    while True:
        collect_metrics(client)
        time.sleep(60)
```

### Slack Bot

```python
import os
from slack_bolt import App

app = App(token=os.environ["SLACK_BOT_TOKEN"])
sr_client = ServiceRadarClient(...)

@app.command("/serviceradar-status")
def handle_status(ack, respond):
    ack()
    devices = sr_client.get("/api/v1/devices")["data"]
    unavailable = [d for d in devices if not d.get("is_available")]

    if unavailable:
        respond(f"⚠️ {len(unavailable)} devices unavailable: " +
                ", ".join(d["name"] for d in unavailable[:5]))
    else:
        respond("✅ All devices operational")
```

## Troubleshooting

### "Invalid client credentials"

- Verify client ID and secret are correct
- Check if the client has been revoked
- Ensure no extra whitespace in credentials

### "Insufficient scope"

- Check the scopes granted to the client
- Request the needed scope when obtaining the token
- Create a new client with additional scopes if needed

### "Token expired"

- Implement token caching with refresh logic
- Request a new token before the current one expires

### Rate Limiting

API endpoints are rate-limited. If you receive 429 responses:

- Implement exponential backoff
- Cache responses when possible
- Consider batching requests

## Next Steps

- Review the [API Reference](/api) for available endpoints
- Set up [OIDC SSO](./sso-oidc-setup.md) for user authentication
- Configure [Alerting](./identity-alerts.md) for API credential events
