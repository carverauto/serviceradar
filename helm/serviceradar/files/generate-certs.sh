#!/bin/sh
set -e
CERT_DIR="${CERT_DIR:-./certs}"
DAYS_VALID=3650
COUNTRY="US"
STATE="CA"
LOCALITY="San Francisco"
ORGANIZATION="ServiceRadar"
ORG_UNIT="Kubernetes"
mkdir -p "$CERT_DIR"
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
generate_cert "proton" "serviceradar-proton" "DNS:serviceradar-proton,DNS:proton,DNS:proton.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "nats" "serviceradar-nats" "DNS:serviceradar-nats,DNS:nats,DNS:nats.serviceradar,DNS:serviceradar-nats.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "core" "serviceradar-core" "DNS:serviceradar-core,DNS:core,DNS:core.serviceradar,DNS:serviceradar-core.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "web" "serviceradar-web" "DNS:serviceradar-web,DNS:web,DNS:web.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "kv" "serviceradar-kv" "DNS:serviceradar-kv,DNS:kv,DNS:kv.serviceradar,DNS:serviceradar-kv.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "agent" "serviceradar-agent" "DNS:serviceradar-agent,DNS:agent,DNS:agent.serviceradar,DNS:serviceradar-agent.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "poller" "serviceradar-poller" "DNS:serviceradar-poller,DNS:poller,DNS:poller.serviceradar,DNS:serviceradar-poller.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "snmp-checker" "serviceradar-snmp-checker" "DNS:serviceradar-snmp-checker,DNS:snmp-checker,DNS:snmp-checker.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "db-event-writer" "serviceradar-db-event-writer" "DNS:serviceradar-db-event-writer,DNS:db-event-writer,DNS:db-event-writer.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "zen" "serviceradar-zen" "DNS:serviceradar-zen,DNS:zen,DNS:zen.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "flowgger" "serviceradar-flowgger" "DNS:serviceradar-flowgger,DNS:flowgger,DNS:flowgger.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "otel" "serviceradar-otel" "DNS:serviceradar-otel,DNS:otel,DNS:otel.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "mapper" "serviceradar-mapper" "DNS:serviceradar-mapper,DNS:mapper,DNS:mapper.serviceradar,DNS:serviceradar-mapper.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
generate_cert "trapd" "serviceradar-trapd" "DNS:serviceradar-trapd,DNS:trapd,DNS:trapd.serviceradar,DNS:serviceradar-trapd.{{ .Release.Namespace }}.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
if [ ! -f "$CERT_DIR/jwt-secret" ]; then openssl rand -hex 32 > "$CERT_DIR/jwt-secret"; chmod 640 "$CERT_DIR/jwt-secret"; fi
if [ ! -f "$CERT_DIR/api-key" ]; then openssl rand -hex 32 > "$CERT_DIR/api-key"; chmod 640 "$CERT_DIR/api-key"; fi
