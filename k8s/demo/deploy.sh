#!/bin/bash

# ServiceRadar K8s Deployment Script
# This script deploys the core ServiceRadar services to Kubernetes

set -e

NAMESPACE="serviceradar-staging"
ENVIRONMENT="staging"

echo "🚀 Deploying ServiceRadar to Kubernetes"
echo "Namespace: $NAMESPACE"
echo "Environment: $ENVIRONMENT"

# Create namespace if it doesn't exist
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Generate secrets if not already present
if ! kubectl get secret serviceradar-secrets -n $NAMESPACE >/dev/null 2>&1; then
    echo "⚠️  Secrets not found. Creating from template..."
    echo "Please update the secrets with actual values!"
    
    # Generate random secrets
    JWT_SECRET_RAW=$(openssl rand -hex 32)
    JWT_SECRET=$(echo -n "$JWT_SECRET_RAW" | base64)
    API_KEY=$(openssl rand -hex 32 | base64)
    PROTON_PASSWORD=$(openssl rand -hex 16 | base64)
    ADMIN_PASSWORD_RAW=$(openssl rand -base64 16 | tr -d '=' | head -c 16)
    ADMIN_PASSWORD=$(echo -n "$ADMIN_PASSWORD_RAW" | base64)
    
    # Generate bcrypt hash of admin password (cost 12)
    echo "🔐 Generating bcrypt hash for admin password..."
    if command -v htpasswd >/dev/null 2>&1; then
        ADMIN_BCRYPT_HASH=$(htpasswd -nbB admin "$ADMIN_PASSWORD_RAW" | cut -d: -f2)
    elif command -v python3 >/dev/null 2>&1; then
        ADMIN_BCRYPT_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$ADMIN_PASSWORD_RAW'.encode('utf-8'), bcrypt.gensalt()).decode('utf-8'))")
    else
        echo "❌ Error: Neither htpasswd nor python3 found for bcrypt hashing"
        echo "Please install apache2-utils or python3-bcrypt"
        exit 1
    fi
    
    cat <<EOF | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: Secret
metadata:
  name: serviceradar-secrets
type: Opaque
data:
  jwt-secret: $JWT_SECRET
  api-key: $API_KEY
  proton-password: $PROTON_PASSWORD
  admin-password: $ADMIN_PASSWORD
EOF

    # Create/update the configmap with the generated bcrypt hash
    echo "📝 Creating dynamic configmap with generated credentials..."
    cat <<EOF | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: serviceradar-config
data:
  core-k8s-init.sh: |
    #!/bin/bash
    set -e
    
    echo "🔑 Using API_KEY: \${API_KEY:0:8}... (\${#API_KEY} chars)"
    echo "🔐 Using JWT_SECRET: \${JWT_SECRET:0:8}... (\${#JWT_SECRET} chars)"
    
    # Default configuration path
    CONFIG_PATH="\${CONFIG_PATH:-/etc/serviceradar/core.json}"
    echo "Using configuration from \$CONFIG_PATH"
    
    # Get Proton password from Kubernetes secret (loaded as env var)
    if [ -n "\$PROTON_PASSWORD" ]; then
        echo "Found Proton password from Kubernetes secret"
    else
        echo "Warning: PROTON_PASSWORD environment variable not found"
    fi
    
    # If PROTON_PASSWORD is available, update the config file
    if [ -n "\$PROTON_PASSWORD" ] && [ -f "\$CONFIG_PATH" ]; then
        echo "Updating configuration with Proton password..."
        # Create a copy of the config with the password injected
        cp "\$CONFIG_PATH" /tmp/core-original.json
        jq --arg pwd "\$PROTON_PASSWORD" '.database.password = \$pwd' /tmp/core-original.json > /tmp/core.json
        CONFIG_PATH="/tmp/core.json"
    fi
    
    # Wait for Proton to be ready
    if [ "\${WAIT_FOR_PROTON:-false}" = "true" ]; then
        PROTON_TLS_ADDR="\${PROTON_HOST:-serviceradar-proton}:9440"
        PROTON_HTTP_ADDR="\${PROTON_HOST:-serviceradar-proton}:8123"
        echo "Waiting for Proton TLS port at \$PROTON_TLS_ADDR..."
        for i in {1..30}; do
            # First check if TLS port is listening (using openssl to test TLS connectivity)
            if echo "QUIT" | openssl s_client -connect \$PROTON_TLS_ADDR -cert /etc/serviceradar/certs/core.pem -key /etc/serviceradar/certs/core-key.pem -CAfile /etc/serviceradar/certs/root.pem -servername proton.serviceradar -quiet > /dev/null 2>&1; then
                echo "Proton TLS port is ready!"
                # Also verify HTTP for initialization queries (optional)
                if [ -n "\$PROTON_PASSWORD" ]; then
                    if curl -sf "http://default:\${PROTON_PASSWORD}@\$PROTON_HTTP_ADDR/?query=SELECT%201" > /dev/null 2>&1; then
                        echo "Proton HTTP authentication is working!"
                    else
                        echo "TLS is working, HTTP auth may not be ready yet but proceeding..."
                    fi
                else
                    echo "Warning: No password found for Proton authentication"
                fi
                break
            fi
            echo "Waiting for Proton TLS... (\$i/30)"
            sleep 2
        done
    fi
    
    # Initialize database if requested
    if [ "\${INIT_DB:-false}" = "true" ]; then
        echo "Initializing database tables..."
    fi
    
    echo "🔍 Final environment check:"
    echo "  API_KEY: \${API_KEY:0:8}... (\${#API_KEY} chars)"
    echo "  JWT_SECRET: \${JWT_SECRET:0:8}... (\${#JWT_SECRET} chars)"
    echo "  AUTH_ENABLED: \${AUTH_ENABLED:-true}"
    
    # Start the core service
    exec /usr/local/bin/serviceradar-core --config="\$CONFIG_PATH"

  core.json: |
    {
      "listen_addr": ":8090",
      "grpc_addr": ":50052",
      "database": {
        "addresses": [
          "serviceradar-proton:9440"
        ],
        "name": "default",
        "username": "default",
        "password": "",
        "max_conns": 10,
        "idle_conns": 5,
        "tls": {
          "cert_file": "/etc/serviceradar/certs/core.pem",
          "key_file": "/etc/serviceradar/certs/core-key.pem",
          "ca_file": "/etc/serviceradar/certs/root.pem",
          "server_name": "proton.serviceradar"
        },
        "settings": {
          "max_execution_time": 60,
          "output_format_json_quote_64bit_int": 0,
          "allow_experimental_live_view": 1,
          "idle_connection_timeout": 600,
          "join_use_nulls": 1,
          "input_format_defaults_for_omitted_fields": 1
        }
      },
      "alert_threshold": "5m",
      "known_pollers": ["k8s-poller"],
      "metrics": {
        "enabled": true,
        "retention": 100,
        "max_nodes": 10000
      },
      "security": {
        "mode": "mtls",
        "cert_dir": "/etc/serviceradar/certs",
        "role": "core",
        "server_name": "proton.serviceradar",
        "tls": {
          "cert_file": "/etc/serviceradar/certs/core.pem",
          "key_file": "/etc/serviceradar/certs/core-key.pem",
          "ca_file": "/etc/serviceradar/certs/root.pem",
          "client_ca_file": "/etc/serviceradar/certs/root.pem",
          "skip_verify": false
        }
      },
      "cors": {
        "allowed_origins": [
          "*"
        ],
        "allow_credentials": true
      },
      "auth": {
        "jwt_secret": "$JWT_SECRET_RAW",
        "jwt_expiration": "24h",
        "local_users": {
          "admin": "$ADMIN_BCRYPT_HASH"
        }
      },
      "events": {
        "enabled": true,
        "stream_name": "events",
        "subjects": ["poller.health.*", "poller.status.*"]
      },
      "nats": {
        "url": "nats://serviceradar-nats:4222",
        "max_reconnects": 10,
        "reconnect_wait": "2s",
        "drain_timeout": "30s"
      },
      "snmp": {
        "enabled": false,
        "listen_addr": ":161",
        "community": "public",
        "timeout": "5s",
        "retries": 3
      },
      "write_buffer": {
        "size": 10000,
        "flush_interval": "5s",
        "max_retries": 3,
        "retry_delay": "1s"
      },
      "logging": {
        "level": "info",
        "debug": false,
        "output": "stdout",
        "time_format": "",
        "otel": {
          "enabled": false,
          "endpoint": "127.0.0.1:4317",
          "service_name": "serviceradar-core",
          "batch_timeout": "5s",
          "insecure": true,
          "headers": {}
        }
      },
      "webhooks": [
        {
          "enabled": false,
          "url": "https://your-webhook-url",
          "cooldown": "15m",
          "headers": [
            {
              "key": "Authorization",
              "value": "Bearer your-token"
            }
          ]
        }
      ],
      "mcp": {
        "enabled": true
      }
    }
EOF

    echo "✅ Dynamic configmap created with bcrypt hash"
else
    echo "✅ Secrets already exist, skipping generation"
fi

# Check if ghcr.io credentials exist
if ! kubectl get secret ghcr-io-cred -n $NAMESPACE >/dev/null 2>&1; then
    echo "⚠️  GitHub Container Registry credentials not found!"
    echo "Please create the secret manually:"
    echo "kubectl create secret docker-registry ghcr-io-cred \\"
    echo "  --docker-server=ghcr.io \\"
    echo "  --docker-username=YOUR_GITHUB_USERNAME \\"
    echo "  --docker-password=YOUR_GITHUB_TOKEN \\"
    echo "  --namespace=$NAMESPACE"
    exit 1
fi

# Apply kustomization
echo "📦 Applying base configuration..."
kubectl apply -k base/ -n $NAMESPACE

# Apply environment-specific configuration
echo "📦 Applying $ENVIRONMENT configuration..."
kubectl apply -k $ENVIRONMENT/ -n $NAMESPACE

# Wait for deployments
echo "⏳ Waiting for deployments to be ready..."

# Wait for Proton first (database)
kubectl wait --for=condition=available --timeout=300s deployment/serviceradar-proton -n $NAMESPACE

# Wait for NATS
kubectl wait --for=condition=available --timeout=180s deployment/serviceradar-nats -n $NAMESPACE

# Wait for Core
kubectl wait --for=condition=available --timeout=180s deployment/serviceradar-core -n $NAMESPACE

# Wait for Web
kubectl wait --for=condition=available --timeout=180s deployment/serviceradar-web -n $NAMESPACE

# Get service endpoints
echo ""
echo "✅ Deployment complete!"
echo ""
echo "📊 Service Status:"
kubectl get deployments -n $NAMESPACE
echo ""
kubectl get services -n $NAMESPACE
echo ""

# Get ingress URL if available
INGRESS_URL=$(kubectl get ingress -n $NAMESPACE -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "Not configured")
if [ "$INGRESS_URL" != "Not configured" ]; then
    echo "🌐 Access ServiceRadar at: http://$INGRESS_URL"
else
    # Try to get LoadBalancer IP from web service
    LB_IP=$(kubectl get svc serviceradar-web -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$LB_IP" ]; then
        echo "🌐 Access ServiceRadar at: http://$LB_IP:3000"
    else
        echo "🌐 Use port-forward to access ServiceRadar:"
        echo "   kubectl port-forward -n $NAMESPACE svc/serviceradar-web 3000:3000"
        echo "   Then access at: http://localhost:3000"
    fi
fi

echo ""
echo "🔐 Admin credentials:"
echo "   Username: admin"
if ! kubectl get secret serviceradar-secrets -n $NAMESPACE >/dev/null 2>&1; then
    echo "   Password: $ADMIN_PASSWORD_RAW"
else
    echo "   Password: (stored in secret 'serviceradar-secrets', key 'admin-password')"
    echo "   To retrieve: kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d"
fi
echo ""
echo "⚠️  Store these credentials securely!"
