#!/bin/sh
set -e
CERT_DIR="${CERT_DIR:-./certs}"
DAYS_VALID=3650
TENANT_CA_DAYS_VALID=3650
COMPONENT_DAYS_VALID=365
COUNTRY="US"
STATE="CA"
LOCALITY="San Francisco"
ORGANIZATION="ServiceRadar"
ORG_UNIT="Kubernetes"
DEFAULT_TENANT_SLUG="${DEFAULT_TENANT_SLUG:-default}"
DEFAULT_PARTITION_ID="${DEFAULT_PARTITION_ID:-partition-1}"
mkdir -p "$CERT_DIR"
mkdir -p "$CERT_DIR/tenants"
chmod 755 "$CERT_DIR"
if [ ! -f "$CERT_DIR/root.pem" ]; then
  openssl genrsa -out "$CERT_DIR/root-key.pem" 4096
  openssl req -new -x509 -sha256 -key "$CERT_DIR/root-key.pem" -out "$CERT_DIR/root.pem" -days $DAYS_VALID -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORG_UNIT/CN=ServiceRadar Root CA"
  chmod 644 "$CERT_DIR/root.pem"; chmod 640 "$CERT_DIR/root-key.pem"
fi
generate_cert() {
  local component=$1; local cn=$2; local san=$3
  if [ -f "$CERT_DIR/$component.pem" ] && [ "$FORCE_REGENERATE" != "true" ]; then return; fi
  openssl genrsa -out "$CERT_DIR/$component-key.pem" 2048
  cat > "$CERT_DIR/$component.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $LOCALITY
O = $ORGANIZATION
OU = $ORG_UNIT
CN = $cn
[v3_req]
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = $san
EOF
  openssl req -new -sha256 -key "$CERT_DIR/$component-key.pem" -out "$CERT_DIR/$component.csr" -config "$CERT_DIR/$component.conf"
  openssl x509 -req -in "$CERT_DIR/$component.csr" -CA "$CERT_DIR/root.pem" -CAkey "$CERT_DIR/root-key.pem" -CAcreateserial -out "$CERT_DIR/$component.pem" -days $DAYS_VALID -sha256 -extensions v3_req -extfile "$CERT_DIR/$component.conf"
  rm "$CERT_DIR/$component.csr" "$CERT_DIR/$component.conf"; chmod 644 "$CERT_DIR/$component.pem" "$CERT_DIR/$component-key.pem"
}
generate_cert "nats" "serviceradar-nats" "DNS:serviceradar-nats,DNS:nats,DNS:nats.serviceradar,DNS:serviceradar-nats.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "core" "serviceradar-core" "DNS:serviceradar-core,DNS:core,DNS:core.serviceradar,DNS:serviceradar-core.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "web" "serviceradar-web-ng" "DNS:serviceradar-web-ng,DNS:web-ng,DNS:serviceradar-web,DNS:web,DNS:web.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "kv" "serviceradar-datasvc" "DNS:serviceradar-datasvc,DNS:kv,DNS:datasvc.serviceradar,DNS:serviceradar-datasvc.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "agent" "serviceradar-agent" "DNS:serviceradar-agent,DNS:agent,DNS:agent.serviceradar,DNS:serviceradar-agent.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "poller" "serviceradar-poller" "DNS:serviceradar-poller,DNS:poller,DNS:poller.serviceradar,DNS:serviceradar-poller.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "snmp-checker" "serviceradar-snmp-checker" "DNS:serviceradar-snmp-checker,DNS:snmp-checker,DNS:snmp-checker.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "rperf-client" "serviceradar-rperf-client" "DNS:serviceradar-rperf-client,DNS:rperf-client,DNS:serviceradar-rperf,DNS:localhost,IP:127.0.0.1"
generate_cert "db-event-writer" "serviceradar-db-event-writer" "DNS:serviceradar-db-event-writer,DNS:db-event-writer,DNS:db-event-writer.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "zen" "serviceradar-zen" "DNS:serviceradar-zen,DNS:zen,DNS:zen.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "flowgger" "serviceradar-flowgger" "DNS:serviceradar-flowgger,DNS:flowgger,DNS:flowgger.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "otel" "serviceradar-otel" "DNS:serviceradar-otel,DNS:otel,DNS:otel.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "mapper" "serviceradar-mapper" "DNS:serviceradar-mapper,DNS:mapper,DNS:mapper.serviceradar,DNS:serviceradar-mapper.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "trapd" "serviceradar-trapd" "DNS:serviceradar-trapd,DNS:trapd,DNS:trapd.serviceradar,DNS:serviceradar-trapd.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "client" "serviceradar-debug-client" "DNS:serviceradar-tools,DNS:client,DNS:debug-client,DNS:localhost,IP:127.0.0.1"
if [ ! -f "$CERT_DIR/jwt-secret" ]; then openssl rand -hex 32 > "$CERT_DIR/jwt-secret"; chmod 640 "$CERT_DIR/jwt-secret"; fi
if [ ! -f "$CERT_DIR/api-key" ]; then openssl rand -hex 32 > "$CERT_DIR/api-key"; chmod 640 "$CERT_DIR/api-key"; fi

# Tenant CA generation function
generate_tenant_ca() {
  local tenant_slug=$1
  local tenant_dir="$CERT_DIR/tenants/$tenant_slug"
  mkdir -p "$tenant_dir"
  if [ -f "$tenant_dir/ca.pem" ] && [ "$FORCE_REGENERATE" != "true" ]; then return; fi
  local cn="tenant-${tenant_slug}.ca.serviceradar"
  openssl genrsa -out "$tenant_dir/ca-key.pem" 4096
  cat > "$tenant_dir/ca.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_ca
prompt = no
[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $LOCALITY
O = $ORGANIZATION
OU = Tenant-$tenant_slug
CN = $cn
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  openssl req -new -sha256 -key "$tenant_dir/ca-key.pem" -out "$tenant_dir/ca.csr" -config "$tenant_dir/ca.conf"
  openssl x509 -req -in "$tenant_dir/ca.csr" -CA "$CERT_DIR/root.pem" -CAkey "$CERT_DIR/root-key.pem" -CAcreateserial -out "$tenant_dir/ca.pem" -days $TENANT_CA_DAYS_VALID -sha256 -extensions v3_ca -extfile "$tenant_dir/ca.conf"
  cat "$tenant_dir/ca.pem" "$CERT_DIR/root.pem" > "$tenant_dir/ca-chain.pem"
  rm "$tenant_dir/ca.csr" "$tenant_dir/ca.conf"
  chmod 644 "$tenant_dir/ca.pem" "$tenant_dir/ca-chain.pem"; chmod 600 "$tenant_dir/ca-key.pem"
}

# Tenant component certificate generation
generate_tenant_component_cert() {
  local tenant_slug=$1; local component_id=$2; local partition_id=$3; local extra_san="${4:-}"
  local tenant_dir="$CERT_DIR/tenants/$tenant_slug"
  local component_dir="$tenant_dir/components"
  local cert_name="${component_id}-${partition_id}"
  mkdir -p "$component_dir"
  if [ -f "$component_dir/$cert_name.pem" ] && [ "$FORCE_REGENERATE" != "true" ]; then return; fi
  local cn="${component_id}.${partition_id}.${tenant_slug}.serviceradar"
  local spiffe_id="spiffe://serviceradar.local/${component_id}/${tenant_slug}/${partition_id}"
  local san="DNS:$cn,DNS:${component_id}.serviceradar,DNS:localhost,IP:127.0.0.1,URI:$spiffe_id"
  [ -n "$extra_san" ] && san="${san},${extra_san}"
  openssl genrsa -out "$component_dir/$cert_name-key.pem" 2048
  cat > "$component_dir/$cert_name.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $LOCALITY
O = $ORGANIZATION
OU = Tenant-$tenant_slug
CN = $cn
[v3_req]
basicConstraints = CA:FALSE
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = $san
EOF
  openssl req -new -sha256 -key "$component_dir/$cert_name-key.pem" -out "$component_dir/$cert_name.csr" -config "$component_dir/$cert_name.conf"
  openssl x509 -req -in "$component_dir/$cert_name.csr" -CA "$tenant_dir/ca.pem" -CAkey "$tenant_dir/ca-key.pem" -CAcreateserial -out "$component_dir/$cert_name.pem" -days $COMPONENT_DAYS_VALID -sha256 -extensions v3_req -extfile "$component_dir/$cert_name.conf"
  cat "$component_dir/$cert_name.pem" "$tenant_dir/ca-chain.pem" > "$component_dir/$cert_name-chain.pem"
  rm "$component_dir/$cert_name.csr" "$component_dir/$cert_name.conf"
  chmod 644 "$component_dir/$cert_name.pem" "$component_dir/$cert_name-chain.pem"; chmod 600 "$component_dir/$cert_name-key.pem"
}

# Generate default tenant CA and component certs for development
generate_tenant_ca "$DEFAULT_TENANT_SLUG"
generate_tenant_component_cert "$DEFAULT_TENANT_SLUG" "agent-001" "$DEFAULT_PARTITION_ID" "DNS:agent,DNS:serviceradar-agent"
generate_tenant_component_cert "$DEFAULT_TENANT_SLUG" "poller-001" "$DEFAULT_PARTITION_ID" "DNS:poller,DNS:serviceradar-poller"
