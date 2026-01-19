#!/bin/sh
set -e
CERT_DIR="${CERT_DIR:-./certs}"
DAYS_VALID=3650
COMPONENT_DAYS_VALID=365
COUNTRY="US"
STATE="CA"
LOCALITY="San Francisco"
ORGANIZATION="ServiceRadar"
ORG_UNIT="Kubernetes"
DEFAULT_PARTITION_ID="${DEFAULT_PARTITION_ID:-partition-1}"
DEFAULT_AGENT_COMPONENT_ID="${DEFAULT_AGENT_COMPONENT_ID:-agent-001}"
mkdir -p "$CERT_DIR"
mkdir -p "$CERT_DIR/components"
chmod 755 "$CERT_DIR"
if [ ! -f "$CERT_DIR/root.pem" ]; then
  openssl genrsa -out "$CERT_DIR/root-key.pem" 4096
  openssl req -new -x509 -sha256 -key "$CERT_DIR/root-key.pem" -out "$CERT_DIR/root.pem" -days $DAYS_VALID -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORG_UNIT/CN=ServiceRadar Root CA"
  chmod 644 "$CERT_DIR/root.pem"; chmod 640 "$CERT_DIR/root-key.pem"
fi
if [ ! -f "$CERT_DIR/cnpg-ca.pem" ] || [ "$FORCE_REGENERATE" = "true" ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/cnpg-ca-key.pem"
  cat > "$CERT_DIR/cnpg-ca.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no
[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $LOCALITY
O = $ORGANIZATION
OU = $ORG_UNIT
CN = ServiceRadar CNPG CA
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  openssl req -new -x509 -sha256 -key "$CERT_DIR/cnpg-ca-key.pem" -out "$CERT_DIR/cnpg-ca.pem" -days $DAYS_VALID -config "$CERT_DIR/cnpg-ca.conf"
  rm "$CERT_DIR/cnpg-ca.conf"
  chmod 644 "$CERT_DIR/cnpg-ca.pem"; chmod 600 "$CERT_DIR/cnpg-ca-key.pem"
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
  rm "$CERT_DIR/$component.csr" "$CERT_DIR/$component.conf"; chmod 644 "$CERT_DIR/$component.pem"; chmod 640 "$CERT_DIR/$component-key.pem"
}
generate_cert "nats" "serviceradar-nats" "DNS:serviceradar-nats,DNS:nats,DNS:nats.serviceradar,DNS:serviceradar-nats.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "core" "serviceradar-core" "DNS:serviceradar-core,DNS:core,DNS:core.serviceradar,DNS:serviceradar-core.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "web" "serviceradar-web-ng" "DNS:serviceradar-web-ng,DNS:web-ng,DNS:serviceradar-web,DNS:web,DNS:web.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "kv" "serviceradar-datasvc" "DNS:serviceradar-datasvc,DNS:kv,DNS:datasvc.serviceradar,DNS:serviceradar-datasvc.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "agent" "serviceradar-agent" "DNS:serviceradar-agent,DNS:agent,DNS:agent.serviceradar,DNS:serviceradar-agent.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "gateway" "serviceradar-agent-gateway" "DNS:serviceradar-agent-gateway,DNS:agent-gateway,DNS:agent-gateway.serviceradar,DNS:serviceradar-agent-gateway.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "rperf-client" "serviceradar-rperf-client" "DNS:serviceradar-rperf-client,DNS:rperf-client,DNS:serviceradar-rperf,DNS:localhost,IP:127.0.0.1"
generate_cert "db-event-writer" "serviceradar-db-event-writer" "DNS:serviceradar-db-event-writer,DNS:db-event-writer,DNS:db-event-writer.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "zen" "serviceradar-zen" "DNS:serviceradar-zen,DNS:zen,DNS:zen.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "flowgger" "serviceradar-flowgger" "DNS:serviceradar-flowgger,DNS:flowgger,DNS:flowgger.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "otel" "serviceradar-otel" "DNS:serviceradar-otel,DNS:otel,DNS:otel.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "trapd" "serviceradar-trapd" "DNS:serviceradar-trapd,DNS:trapd,DNS:trapd.serviceradar,DNS:serviceradar-trapd.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "client" "serviceradar-debug-client" "DNS:serviceradar-tools,DNS:client,DNS:debug-client,DNS:localhost,IP:127.0.0.1"
if [ ! -f "$CERT_DIR/cnpg-client.pem" ] || [ "$FORCE_REGENERATE" = "true" ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/cnpg-client-key.pem"
  cat > "$CERT_DIR/cnpg-client.conf" <<EOF
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
CN = serviceradar-cnpg-client
[v3_req]
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
subjectAltName = DNS:serviceradar-cnpg-client
EOF
  openssl req -new -sha256 -key "$CERT_DIR/cnpg-client-key.pem" -out "$CERT_DIR/cnpg-client.csr" -config "$CERT_DIR/cnpg-client.conf"
  openssl x509 -req -in "$CERT_DIR/cnpg-client.csr" -CA "$CERT_DIR/cnpg-ca.pem" -CAkey "$CERT_DIR/cnpg-ca-key.pem" -CAcreateserial -out "$CERT_DIR/cnpg-client.pem" -days $DAYS_VALID -sha256 -extensions v3_req -extfile "$CERT_DIR/cnpg-client.conf"
  rm "$CERT_DIR/cnpg-client.csr" "$CERT_DIR/cnpg-client.conf"
  chmod 644 "$CERT_DIR/cnpg-client.pem"; chmod 640 "$CERT_DIR/cnpg-client-key.pem"
fi
if [ ! -f "$CERT_DIR/jwt-secret" ]; then openssl rand -hex 32 > "$CERT_DIR/jwt-secret"; chmod 640 "$CERT_DIR/jwt-secret"; fi
if [ ! -f "$CERT_DIR/api-key" ]; then openssl rand -hex 32 > "$CERT_DIR/api-key"; chmod 640 "$CERT_DIR/api-key"; fi

# Edge component certificate generation
generate_component_cert() {
  local component_type=$1; local component_id=$2; local partition_id=$3; local extra_san="${4:-}"
  local component_dir="$CERT_DIR/components"
  local cert_name="${component_id}-${partition_id}"
  mkdir -p "$component_dir"
  if [ -f "$component_dir/$cert_name.pem" ] && [ "$FORCE_REGENERATE" != "true" ]; then return; fi
  local cn="${component_id}.${partition_id}.serviceradar"
  local spiffe_id="spiffe://serviceradar.local/${component_type}/${partition_id}/${component_id}"
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
OU = Edge
CN = $cn
[v3_req]
basicConstraints = CA:FALSE
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = $san
EOF
  openssl req -new -sha256 -key "$component_dir/$cert_name-key.pem" -out "$component_dir/$cert_name.csr" -config "$component_dir/$cert_name.conf"
  openssl x509 -req -in "$component_dir/$cert_name.csr" -CA "$CERT_DIR/root.pem" -CAkey "$CERT_DIR/root-key.pem" -CAcreateserial -out "$component_dir/$cert_name.pem" -days $COMPONENT_DAYS_VALID -sha256 -extensions v3_req -extfile "$component_dir/$cert_name.conf"
  cat "$component_dir/$cert_name.pem" "$CERT_DIR/root.pem" > "$component_dir/$cert_name-chain.pem"
  rm "$component_dir/$cert_name.csr" "$component_dir/$cert_name.conf"
  chmod 644 "$component_dir/$cert_name.pem" "$component_dir/$cert_name-chain.pem"; chmod 600 "$component_dir/$cert_name-key.pem"
}

# Generate default component cert for development
generate_component_cert "agent" "$DEFAULT_AGENT_COMPONENT_ID" "$DEFAULT_PARTITION_ID" "DNS:agent,DNS:serviceradar-agent"
