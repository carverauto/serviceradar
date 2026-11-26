#!/bin/sh
set -e
CERT_DIR="${CERT_DIR:-./certs}"
DAYS_VALID=3650
COMPONENT_DAYS_VALID=365
FORCE_REGENERATE="${FORCE_REGENERATE:-false}"
ROTATE_ROOT_CA="${ROTATE_ROOT_CA:-false}"
ROTATE_CNPG_CA="${ROTATE_CNPG_CA:-false}"
# NAMES_ONLY=true is the pass an upgrade runs over certificates it is keeping:
# it reissues a certificate that lacks a name it is now asked to carry, from the
# same root CA, and creates nothing that is missing. Each reissued certificate's
# name is appended to REISSUED_LIST when that is set.
NAMES_ONLY="${NAMES_ONLY:-false}"
REISSUED_LIST="${REISSUED_LIST:-}"
REISSUED=" "
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
if [ ! -f "$CERT_DIR/root.pem" ] || [ "$ROTATE_ROOT_CA" = "true" ]; then
  openssl genrsa -out "$CERT_DIR/root-key.pem" 4096
  openssl req -new -x509 -sha256 -key "$CERT_DIR/root-key.pem" -out "$CERT_DIR/root.pem" -days $DAYS_VALID -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORG_UNIT/CN=ServiceRadar Root CA"
  chmod 644 "$CERT_DIR/root.pem"; chmod 640 "$CERT_DIR/root-key.pem"
fi
if [ "$NAMES_ONLY" != "true" ] && { [ ! -f "$CERT_DIR/cnpg-ca.pem" ] || [ "$ROTATE_CNPG_CA" = "true" ]; }; then
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
# Succeeds when the certificate carries every requested DNS, URI and IPv4 name.
# A removed name is not a reason to reissue. IPv6 names are not compared:
# openssl prints them in its own spelling, and a comparison that never matched
# would reissue the certificate on every upgrade. A certificate whose names
# cannot be read is left alone for the same reason.
cert_has_names() {
  local cert=$1; local wanted=$2; local present; local name
  present=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | sed -e 1d | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e 's/^IP Address:/IP:/') || return 0
  [ -n "$present" ] || return 0
  for name in $(printf '%s' "$wanted" | tr ',' ' '); do
    case "$name" in
      DNS:*|URI:*) ;;
      IP:*.*) ;;
      *) continue ;;
    esac
    printf '%s\n' "$present" | grep -qxF -- "$name" || return 1
  done
  return 0
}
was_reissued() {
  case "$REISSUED" in *" $1 "*) return 0 ;; esac
  return 1
}
should_copy() {
  local dst=$1; local component="${2:-}"
  [ "$FORCE_REGENERATE" = "true" ] && return 0
  [ -n "$component" ] && was_reissued "$component" && return 0
  [ "$NAMES_ONLY" != "true" ] && [ ! -f "$dst" ]
}
generate_cert() {
  local component=$1; local cn=$2; local san=$3
  if [ -f "$CERT_DIR/$component.pem" ] && [ "$FORCE_REGENERATE" != "true" ]; then
    if cert_has_names "$CERT_DIR/$component.pem" "$san"; then return; fi
    echo "Reissuing $component.pem: it lacks a name it is now asked to carry"
    REISSUED="$REISSUED$component "
    if [ -n "$REISSUED_LIST" ]; then echo "$component.pem" >> "$REISSUED_LIST"; fi
  elif [ ! -f "$CERT_DIR/$component.pem" ] && [ "$NAMES_ONLY" = "true" ]; then
    return
  fi
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
generate_cert "nats" "serviceradar-nats" "DNS:serviceradar-nats,DNS:serviceradar-nats-headless,DNS:nats,DNS:nats.serviceradar,DNS:serviceradar-nats.{{ .Release.Namespace }}.svc.cluster.local,DNS:serviceradar-nats-headless.{{ .Release.Namespace }}.svc.cluster.local,DNS:*.serviceradar-nats-headless.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1{{ include "serviceradar.natsLeafCertSans" . }}"
generate_cert "core" "serviceradar-core" "DNS:serviceradar-core,DNS:core,DNS:core.serviceradar,DNS:serviceradar-core.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "web" "serviceradar-web-ng" "DNS:serviceradar-web-ng,DNS:web-ng,DNS:serviceradar-web,DNS:web,DNS:web.serviceradar,DNS:serviceradar-web-ng.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "kv" "serviceradar-datasvc" "DNS:serviceradar-datasvc,DNS:kv,DNS:datasvc.serviceradar,DNS:serviceradar-datasvc.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "agent" "serviceradar-agent" "DNS:serviceradar-agent,DNS:agent,DNS:agent.serviceradar,DNS:serviceradar-agent.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "gateway" "serviceradar-agent-gateway" "DNS:serviceradar-agent-gateway,DNS:agent-gateway,DNS:agent-gateway.serviceradar,DNS:serviceradar-agent-gateway.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1{{- if .Values.agentGateway.publicHostname }},DNS:{{ .Values.agentGateway.publicHostname }}{{- end }}"
generate_cert "log-collector" "serviceradar-log-collector" "DNS:serviceradar-log-collector,DNS:log-collector,DNS:log-collector.serviceradar,DNS:serviceradar-log-collector.{{ .Release.Namespace }}.svc.cluster.local,DNS:serviceradar-log-collector-tcp.{{ .Release.Namespace }}.svc.cluster.local,DNS:serviceradar-otlp.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "flow-collector" "serviceradar-flow-collector" "DNS:serviceradar-flow-collector,DNS:flow-collector,DNS:flow-collector.serviceradar,DNS:serviceradar-flow-collector.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "bmp-collector" "serviceradar-bmp-collector" "DNS:serviceradar-bmp-collector,DNS:bmp-collector,DNS:bmp-collector.serviceradar,DNS:serviceradar-bmp-collector.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "falcosidekick" "serviceradar-falcosidekick" "DNS:serviceradar-falcosidekick,DNS:falcosidekick,DNS:falcosidekick-nats-auth,DNS:localhost,IP:127.0.0.1"
generate_cert "trivy-sidecar" "serviceradar-trivy-sidecar" "DNS:serviceradar-trivy-sidecar,DNS:trivy-sidecar,DNS:trivy-sidecar.serviceradar,DNS:serviceradar-trivy-sidecar.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "k8s-inventory" "serviceradar-k8s-inventory" "DNS:serviceradar-k8s-inventory,DNS:k8s-inventory,DNS:k8s-inventory.serviceradar,DNS:serviceradar-k8s-inventory.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "trapd" "serviceradar-trapd" "DNS:serviceradar-trapd,DNS:trapd,DNS:trapd.serviceradar,DNS:serviceradar-trapd.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
{{- if eq (include "serviceradar.vantageEnabled" .) "true" }}
generate_cert "media-worker" "serviceradar-media-worker" "DNS:serviceradar-media-worker,DNS:media-worker,DNS:serviceradar-media-worker.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
{{- end }}
generate_cert "tools" "serviceradar-tools" "DNS:serviceradar-tools,DNS:tools,DNS:client,DNS:debug-client,DNS:localhost,IP:127.0.0.1"
if [ -f "$CERT_DIR/root.pem" ] && should_copy "$CERT_DIR/ca.crt"; then
  cp "$CERT_DIR/root.pem" "$CERT_DIR/ca.crt"
  chmod 644 "$CERT_DIR/ca.crt"
fi
if [ -f "$CERT_DIR/tools.pem" ] && should_copy "$CERT_DIR/client.pem" tools; then
  cp "$CERT_DIR/tools.pem" "$CERT_DIR/client.pem"
  chmod 644 "$CERT_DIR/client.pem"
fi
if [ -f "$CERT_DIR/tools-key.pem" ] && should_copy "$CERT_DIR/client-key.pem" tools; then
  cp "$CERT_DIR/tools-key.pem" "$CERT_DIR/client-key.pem"
  chmod 640 "$CERT_DIR/client-key.pem"
fi
if [ -f "$CERT_DIR/flow-collector.pem" ] && [ -f "$CERT_DIR/flow-collector-key.pem" ]; then
  if should_copy "$CERT_DIR/flow-client.crt" flow-collector; then
    cp "$CERT_DIR/flow-collector.pem" "$CERT_DIR/flow-client.crt"
    chmod 644 "$CERT_DIR/flow-client.crt"
  fi
  if should_copy "$CERT_DIR/flow-client.key" flow-collector; then
    cp "$CERT_DIR/flow-collector-key.pem" "$CERT_DIR/flow-client.key"
    chmod 600 "$CERT_DIR/flow-client.key"
  fi
fi
if [ -f "$CERT_DIR/flow-collector.pem" ] && should_copy "$CERT_DIR/netflow-collector.pem" flow-collector; then
  cp "$CERT_DIR/flow-collector.pem" "$CERT_DIR/netflow-collector.pem"
  chmod 644 "$CERT_DIR/netflow-collector.pem"
fi
if [ -f "$CERT_DIR/flow-collector-key.pem" ] && should_copy "$CERT_DIR/netflow-collector-key.pem" flow-collector; then
  cp "$CERT_DIR/flow-collector-key.pem" "$CERT_DIR/netflow-collector-key.pem"
  chmod 600 "$CERT_DIR/netflow-collector-key.pem"
fi
if [ -f "$CERT_DIR/log-collector.pem" ] && should_copy "$CERT_DIR/flowgger.pem" log-collector; then
  cp "$CERT_DIR/log-collector.pem" "$CERT_DIR/flowgger.pem"
  chmod 644 "$CERT_DIR/flowgger.pem"
fi
if [ -f "$CERT_DIR/log-collector-key.pem" ] && should_copy "$CERT_DIR/flowgger-key.pem" log-collector; then
  cp "$CERT_DIR/log-collector-key.pem" "$CERT_DIR/flowgger-key.pem"
  chmod 600 "$CERT_DIR/flowgger-key.pem"
fi
if [ -f "$CERT_DIR/log-collector.pem" ] && should_copy "$CERT_DIR/otel.pem" log-collector; then
  cp "$CERT_DIR/log-collector.pem" "$CERT_DIR/otel.pem"
  chmod 644 "$CERT_DIR/otel.pem"
fi
if [ -f "$CERT_DIR/log-collector-key.pem" ] && should_copy "$CERT_DIR/otel-key.pem" log-collector; then
  cp "$CERT_DIR/log-collector-key.pem" "$CERT_DIR/otel-key.pem"
  chmod 600 "$CERT_DIR/otel-key.pem"
fi
if [ "$NAMES_ONLY" = "true" ]; then exit 0; fi
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
