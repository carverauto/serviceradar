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

    echo "✅ Secrets created successfully"
else
    echo "✅ Secrets already exist, extracting values..."
    # Extract existing values for configmap generation
    ADMIN_PASSWORD_RAW=$(kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d)
    JWT_SECRET_RAW=$(kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.jwt-secret}' | base64 -d)
    
    # Generate bcrypt hash for existing admin password
    echo "🔐 Generating bcrypt hash for existing admin password..."
    if command -v htpasswd >/dev/null 2>&1; then
        ADMIN_BCRYPT_HASH=$(htpasswd -nbB admin "$ADMIN_PASSWORD_RAW" | cut -d: -f2)
    elif command -v python3 >/dev/null 2>&1; then
        ADMIN_BCRYPT_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$ADMIN_PASSWORD_RAW'.encode('utf-8'), bcrypt.gensalt()).decode('utf-8'))")
    else
        echo "❌ Error: Neither htpasswd nor python3 found for bcrypt hashing"
        exit 1
    fi
fi

# Always create/update the complete configmap with all required components
echo "📝 Creating complete configmap with all required components..."
cat <<EOF | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: serviceradar-config
data:
  core-k8s-init.sh: |
    #!/bin/bash
    set -e
    
    # Use the correct environment variable names (with dashes as loaded from secret)
    API_KEY=\$(env | grep '^api-key=' | cut -d'=' -f2-)
    JWT_SECRET=\$(env | grep '^jwt-secret=' | cut -d'=' -f2-)
    
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

  proton-k8s-init.sh: |
    #!/bin/bash
    set -e
    
    echo "[Proton K8s Init] Starting Kubernetes-specific initialization with TLS"
    
    # Wait for certificates to be available
    echo "[Proton K8s Init] Waiting for TLS certificates..."
    timeout=300
    count=0
    while [ ! -f /etc/serviceradar/certs/proton.pem ] || [ ! -f /etc/serviceradar/certs/root.pem ]; do
      if [ \$count -ge \$timeout ]; then
        echo "[Proton K8s Init] ERROR: Timeout waiting for certificates"
        exit 1
      fi
      echo "[Proton K8s Init] Waiting for certificates... (\$count/\$timeout)"
      sleep 1
      count=\$((count + 1))
    done
    echo "[Proton K8s Init] Certificates found!"
    
    # Create proton-server certs directory and link certificates  
    mkdir -p /etc/proton-server/certs
    ln -sf /etc/serviceradar/certs/proton.pem /etc/proton-server/certs/proton.pem
    ln -sf /etc/serviceradar/certs/proton-key.pem /etc/proton-server/certs/proton-key.pem
    ln -sf /etc/serviceradar/certs/root.pem /etc/proton-server/certs/root.pem
    
    # Skip the original proton-init.sh and do minimal setup directly
    echo "[Proton K8s Init] Setting up minimal proton environment"
    
    # Create required directories
    mkdir -p /var/lib/proton
    mkdir -p /etc/proton-server/users.d
    mkdir -p /var/log/proton-server
    
    # Clean up any existing lock files from previous instances
    echo "[Proton K8s Init] Cleaning up any existing lock files..."
    rm -f /var/lib/proton/status
    rm -f /var/lib/proton/*.lock
    rm -f /var/lib/proton/tmp_*
    
    # Set permissions
    chown -R proton:proton /var/lib/proton
    chown -R proton:proton /var/log/proton-server
    
    # Use password from Kubernetes secret (loaded as environment variable)
    if [ -n "\$PROTON_PASSWORD" ]; then
        echo "[Proton K8s Init] Using password from Kubernetes secret"
        echo "\$PROTON_PASSWORD" > /etc/proton-server/generated_password.txt
        chmod 600 /etc/proton-server/generated_password.txt
        
        # Also save to shared credentials volume for other services
        if [ -d "/etc/serviceradar/credentials" ]; then
            echo "\$PROTON_PASSWORD" > /etc/serviceradar/credentials/proton-password
            chmod 644 /etc/serviceradar/credentials/proton-password
            echo "[Proton K8s Init] Password also saved to shared credentials volume"
        fi
    else
        echo "[Proton K8s Init] ERROR: PROTON_PASSWORD environment variable not found"
        echo "[Proton K8s Init] Cannot start Proton without password from Kubernetes secret"
        exit 1
    fi
    
    # Create password hash for user config
    PASSWORD_HASH=\$(echo -n "\$PROTON_PASSWORD" | sha256sum | awk '{print \$1}')
    
    # Create user configuration
    echo "[Proton K8s Init] Configuring default user password..."
    mkdir -p /etc/proton-server/users.d
    cat > /etc/proton-server/users.d/default-password.xml << END_OF_XML
    <proton>
        <users>
            <default>
                <password remove='1' />
                <password_sha256_hex>\${PASSWORD_HASH}</password_sha256_hex>
                <networks>
                    <ip>0.0.0.0/0</ip>
                </networks>
            </default>
        </users>
    </proton>
    END_OF_XML
    chmod 600 /etc/proton-server/users.d/default-password.xml
    
    echo "[Proton K8s Init] Fixing ownership and starting Proton as proton user"
    chown -R proton:proton /var/lib/proton
    find /etc/proton-server/ -type f ! -path "*/config.d/logger.xml" -exec chown proton:proton {} \;
    find /etc/proton-server/ -type d -exec chown proton:proton {} \;
    
    exec su -s /bin/bash proton -c "/usr/bin/proton server --config-file=/etc/proton-server/config.yaml"

  poller.json: |
    {
      "agents": {
        "k8s-agent": {
          "address": "serviceradar-agent:50051",
          "security": {
            "server_name": "agent.serviceradar",
            "mode": "mtls",
            "cert_dir": "/etc/serviceradar/certs",
            "role": "poller",
            "tls": {
              "cert_file": "poller.pem",
              "key_file": "poller-key.pem",
              "ca_file": "root.pem",
              "client_ca_file": "root.pem"
            }
          },
          "checks": [
            {
              "service_type": "port",
              "service_name": "SSH",
              "details": "serviceradar-agent:22"
            },
            {
              "service_type": "icmp",
              "service_name": "ping",
              "details": "8.8.8.8"
            },
            {
              "service_type": "sweep",
              "service_name": "network_sweep",
              "details": "",
              "results_interval": "2m"
            }
          ]
        }
      },
      "core_address": "serviceradar-core:50052",
      "core_security": {
        "mode": "mtls",
        "cert_dir": "/etc/serviceradar/certs",
        "server_name": "core.serviceradar",
        "role": "poller",
        "tls": {
          "cert_file": "poller.pem",
          "key_file": "poller-key.pem",
          "ca_file": "root.pem"
        }
      },
      "listen_addr": ":50053",
      "poll_interval": "30s",
      "poller_id": "k8s-poller",
      "partition": "default",
      "source_ip": "poller",
      "service_name": "PollerService",
      "service_type": "grpc",
      "security": {
        "mode": "mtls",
        "cert_dir": "/etc/serviceradar/certs",
        "server_name": "poller.serviceradar",
        "role": "poller",
        "tls": {
          "cert_file": "poller.pem",
          "key_file": "poller-key.pem",
          "ca_file": "root.pem",
          "client_ca_file": "root.pem"
        }
      },
      "logging": {
        "level": "info",
        "debug": false,
        "output": "stdout",
        "time_format": "",
        "otel": {
          "enabled": false,
          "endpoint": "otel:4317",
          "service_name": "serviceradar-poller",
          "batch_timeout": "5s",
          "insecure": true,
          "headers": {
            "x-api-key": "your-collector-api-key"
          },
          "tls": {
            "cert_file": "/etc/serviceradar/certs/poller.pem",
            "key_file": "/etc/serviceradar/certs/poller-key.pem",
            "ca_file": "/etc/serviceradar/certs/root.pem"
          }
        }
      }
    }

  nats.conf: |
    # NATS Server Configuration for ServiceRadar Kubernetes Deployment
    server_name: nats-serviceradar-k8s

    # Listen on all interfaces for Kubernetes networking
    listen: 0.0.0.0:4222

    # HTTP monitoring
    http: 0.0.0.0:8222

    # Enable JetStream for KV store
    jetstream {
      # Directory to store JetStream data
      store_dir: /data/jetstream
      # Maximum storage size
      max_memory_store: 1G
      # Maximum disk storage
      max_file_store: 10G
    }

    # Enable mTLS for secure communication
    tls {
      # Path to the server certificate
      cert_file: "/etc/serviceradar/certs/nats.pem"
      # Path to the server private key
      key_file: "/etc/serviceradar/certs/nats-key.pem"
      # Path to the root CA certificate for verifying clients
      ca_file: "/etc/serviceradar/certs/root.pem"

      # Require client certificates (enables mTLS)
      verify: true
      # Require and verify client certificates
      verify_and_map: true
    }

    # Authorization for ServiceRadar components
    authorization {
      users: [
        {
          user: "CN=serviceradar-core,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
          permissions: {
            publish: {
              allow: [">"]
            }
            subscribe: {
              allow: [">"]
            }
          }
        },
        {
          user: "CN=serviceradar-kv,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
          permissions: {
            publish: {
              allow: [">"]
            }
            subscribe: {
              allow: [">"]
            }
          }
        },
        {
          user: "CN=serviceradar-poller,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
          permissions: {
            publish: {
              allow: [">"]
            }
            subscribe: {
              allow: [">"]
            }
          }
        },
        {
          user: "CN=serviceradar-agent,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
          permissions: {
            publish: {
              allow: [">"]
            }
            subscribe: {
              allow: [">"]
            }
          }
        },
        {
          user: "CN=serviceradar-db-event-writer,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
          permissions: {
            publish: {
              allow: [">"]
            }
            subscribe: {
              allow: [">"]
            }
          }
        },
        {
          user: "CN=serviceradar-zen,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
          permissions: {
            publish: {
              allow: [">"]
            }
            subscribe: {
              allow: [">"]
            }
          }
        },
        {
          user: "O=ServiceRadar"
          permissions: {
            publish: {
              allow: [">"]
            }
            subscribe: {
              allow: [">"]
            }
          }
        }
      ]
    }

    # Logging settings
    debug: true
    trace: false

  kv.json: |
    {
      "listen_addr": ":50057",
      "nats_url": "tls://serviceradar-nats:4222",
      "security": {
        "mode": "mtls",
        "cert_dir": "/etc/serviceradar/certs",
        "server_name": "nats.serviceradar",
        "role": "kv",
        "tls": {
          "cert_file": "kv.pem",
          "key_file": "kv-key.pem",
          "ca_file": "root.pem"
        }
      },
      "rbac": {
        "roles": [
          {"identity": "CN=serviceradar-core,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US", "role": "admin"},
          {"identity": "CN=serviceradar-poller,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US", "role": "reader"},
          {"identity": "CN=serviceradar-agent,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US", "role": "reader"}
        ]
      },
      "bucket": "serviceradar-kv"
    }

  agent.json: |
    {
      "checkers_dir": "/etc/serviceradar/checkers",
      "listen_addr": ":50051",
      "service_type": "grpc",
      "service_name": "AgentService",
      "agent_id": "k8s-agent",
      "agent_name": "agent",
      "host_ip": "agent",
      "partition": "default",
      "kv_address": "serviceradar-kv:50057",
      "kv_security": {
        "mode": "mtls",
        "cert_dir": "/etc/serviceradar/certs",
        "server_name": "kv.serviceradar",
        "role": "agent",
        "tls": {
          "cert_file": "agent.pem",
          "key_file": "agent-key.pem",
          "ca_file": "root.pem"
        }
      },
      "security": {
        "mode": "mtls",
        "cert_dir": "/etc/serviceradar/certs",
        "server_name": "agent.serviceradar",
        "role": "agent",
        "tls": {
          "cert_file": "agent.pem",
          "key_file": "agent-key.pem",
          "ca_file": "root.pem"
        }
      },
      "logging": {
        "level": "info",
        "debug": false,
        "output": "stdout",
        "time_format": "",
        "otel": {
          "enabled": false,
          "endpoint": "",
          "service_name": "serviceradar-agent",
          "batch_timeout": "5s",
          "insecure": false,
          "tls": {
            "cert_file": "/etc/serviceradar/certs/agent.pem",
            "key_file": "/etc/serviceradar/certs/agent-key.pem",
            "ca_file": "/etc/serviceradar/certs/root.pem"
          }
        }
      }
    }

  sweep.json: |
    {
      "networks": [
          "192.168.2.0/24",
          "192.168.3.1/32"
      ],
      "ports": [
        22,
        80,
        443,
        3306,
        5432,
        6379,
        8080,
        8443
      ],
      "sweep_modes": [
        "icmp",
        "tcp"
      ],
      "interval": "5m",
      "concurrency": 100,
      "timeout": "10s"
    } 

  external.json: |
    {
      "enabled": true
    }

  snmp.json: |
    {
      "node_address": "serviceradar-core:50052",
      "listen_addr": ":50054",
      "partition": "default",
      "security": {
        "server_name": "serviceradar-core",
        "mode": "mtls",
        "role": "checker",
        "cert_dir": "/etc/serviceradar/certs",
        "tls": {
          "cert_file": "snmp-checker.pem",
          "key_file": "snmp-checker-key.pem",
          "ca_file": "root.pem"
        }
      },
      "timeout": "30s",
      "targets": [
        {
          "name": "test-router",
          "host": "192.168.1.1",
          "port": 161,
          "community": "public",
          "version": "v2c",
          "interval": "30s",
          "retries": 2,
          "oids": [
            {
              "oid": ".1.3.6.1.2.1.2.2.1.10.4",
              "name": "ifInOctets_4",
              "type": "counter",
              "scale": 1.0
            }
          ]
        }
      ]
    }

  proton-logger.xml: |
    <?xml version="1.0"?>
    <proton>
        <logger>
            <level>error</level>
            <console>1</console>
            <log remove="remove"/>
            <errorlog remove="remove"/>
        </logger>
    </proton>

  config.yaml: |
    # Proton Server Configuration for Kubernetes
    logger:
      level: error
      log: /var/log/proton-server/proton-server.log
      errorlog: /var/log/proton-server/proton-server.err.log
      size: 1000M
      count: 10

    # Listen on all interfaces for Kubernetes
    listen_host: 0.0.0.0

    # HTTP port for queries
    snapshot_server_http_port: 8123

    # Native TCP port (non-secure)
    snapshot_server_tcp_port: 8463

    # HTTPS port with TLS
    https_port: 8443

    # Native TCP port with TLS - this is what serviceradar-core connects to
    tcp_port_secure: 9440

    # Enable telemetry (required for MetaStoreServer)
    telemetry_enabled: true
    telemetry_interval_ms: 300000

    # Server settings
    max_connections: 4096
    keep_alive_timeout: 3
    max_thread_pool_size: 10000
    max_server_memory_usage_to_ram_ratio: 0.9

    # Cache settings
    uncompressed_cache_size: 8589934592
    mark_cache_size: 5368709120
    mmap_cache_size: 1000
    compiled_expression_cache_size: 134217728

    # TLS Configuration
    openSSL:
      server:
        # Proton server certificates
        certificateFile: /etc/proton-server/certs/proton.pem
        privateKeyFile: /etc/proton-server/certs/proton-key.pem
        caConfig: /etc/proton-server/certs/root.pem
        verificationMode: relaxed
        loadDefaultCAFile: false
        cacheSessions: false
        disableProtocols: 'sslv2,sslv3'
        preferServerCiphers: true
      client:
        loadDefaultCAFile: true
        cacheSessions: true
        disableProtocols: 'sslv2,sslv3'
        preferServerCiphers: true
        invalidCertificateHandler:
          name: AcceptCertificateHandler

    # Path configuration
    path: /var/lib/proton

    # Users and access control
    user_directories:
      users_xml:
        path: /etc/proton-server/users.d/default-password.xml

  openssl.xml: |
    <?xml version="1.0"?>
    <proton>
        <openSSL>
            <server>
                <certificateFile>/etc/proton-server/certs/proton.pem</certificateFile>
                <privateKeyFile>/etc/proton-server/certs/proton-key.pem</privateKeyFile>
                <caConfig>/etc/proton-server/certs/root.pem</caConfig>
                <verificationMode>relaxed</verificationMode>
                <loadDefaultCAFile>false</loadDefaultCAFile>
                <cacheSessions>false</cacheSessions>
                <disableProtocols>sslv2,sslv3</disableProtocols>
                <preferServerCiphers>true</preferServerCiphers>
            </server>
            <client>
                <loadDefaultCAFile>true</loadDefaultCAFile>
                <cacheSessions>true</cacheSessions>
                <disableProtocols>sslv2,sslv3</disableProtocols>
                <preferServerCiphers>true</preferServerCiphers>
                <invalidCertificateHandler>
                    <name>AcceptCertificateHandler</name>
                </invalidCertificateHandler>
            </client>
        </openSSL>
    </proton>

    db-event-writer.json: |
        {
            "listen_addr": "0.0.0.0:50041",
            "nats_url": "tls://serviceradar-nats:4222",
            "partition": "k8s",
            "stream_name": "events",
            "consumer_name": "db-event-writer",
            "agent_id": "k8s-db-event-writer",
            "poller_id": "k8s-poller",
            "streams": [
                {
                    "subject": "events.poller.health",
                    "table": "events"
                },
                {
                    "subject": "events.syslog.processed", 
                    "table": "events"
                },
                {
                    "subject": "events.snmp.processed",
                    "table": "events" 
                },
                {
                    "subject": "events.otel.logs",
                    "table": "logs"
                },
                {
                    "subject": "events.otel.traces",
                    "table": "otel_traces"
                },
                {
                    "subject": "events.otel.metrics", 
                    "table": "otel_metrics"
                }
            ],
            "database": {
                "addresses": [
                    "serviceradar-proton:9440"
                ],
                "name": "default",
                "username": "default",
                "password": ""
            },
            "security": {
                "mode": "mtls",
                "cert_dir": "/etc/serviceradar/certs",
                "server_name": "localhost",
                "role": "core",
                "tls": {
                    "cert_file": "/etc/serviceradar/certs/db-event-writer.pem",
                    "key_file": "/etc/serviceradar/certs/db-event-writer-key.pem",
                    "ca_file": "/etc/serviceradar/certs/root.pem"
                }
            },
            "nats_security": {
                "mode": "mtls",
                "cert_dir": "/etc/serviceradar/certs",
                "server_name": "nats.serviceradar",
                "role": "client",
                "tls": {
                    "cert_file": "/etc/serviceradar/certs/db-event-writer.pem",
                    "key_file": "/etc/serviceradar/certs/db-event-writer-key.pem",
                    "ca_file": "/etc/serviceradar/certs/root.pem"
                }
            },
            "db_security": {
                "mode": "mtls",
                "cert_dir": "/etc/serviceradar/certs",
                "server_name": "proton.serviceradar",
                "role": "client",
                "tls": {
                    "cert_file": "/etc/serviceradar/certs/db-event-writer.pem",
                    "key_file": "/etc/serviceradar/certs/db-event-writer-key.pem",
                    "ca_file": "/etc/serviceradar/certs/root.pem"
                }
            },
            "logging": {
                "level": "info",
                "debug": false,
                "output": "stdout",
                "time_format": "",
                "otel": {
                    "enabled": false,
                    "endpoint": "otel:4317",
                    "service_name": "serviceradar-db-event-writer",
                    "batch_timeout": "5s",
                    "insecure": false,
                    "tls": {
                        "cert_file": "/etc/serviceradar/certs/db-event-writer.pem",
                        "key_file": "/etc/serviceradar/certs/db-event-writer-key.pem",
                        "ca_file": "/etc/serviceradar/certs/root.pem"
                    }
                }
            }
        }
EOF

echo "✅ Complete configmap created with all required components"

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

# Wait for KV
kubectl wait --for=condition=available --timeout=180s deployment/serviceradar-kv -n $NAMESPACE

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
