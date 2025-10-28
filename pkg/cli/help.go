package cli

import "fmt"

// ShowHelp displays the help message and exits.
func ShowHelp() {
	fmt.Print(`serviceradar: ServiceRadar command-line tool
Usage:
  serviceradar [options] [password]
  serviceradar update-config [options]
  serviceradar update-poller [options]
  serviceradar generate-tls [options]
  serviceradar render-kong [options]
  serviceradar generate-jwt-keys [options]
  serviceradar spire-join-token [options]

Commands:
  (default)        Generate bcrypt hash from password
  update-config    Update core.json with new admin password hash
  update-poller    Manage service checks in poller.json
  generate-tls     Generate mTLS certificates for ServiceRadar and Proton
  render-kong      Render Kong DB-less config from Core JWKS
  generate-jwt-keys Generate RS256 keypair and update core.json
  spire-join-token  Request a join token from Core and optionally register a downstream entry

Options for bcrypt generation:
  -help         show this help message

Options for update-config:
  -file string        path to core.json config file
  -admin-hash string  bcrypt hash for admin user

Options for update-poller:
  -file string        path to poller.json config file
  -action string      action to perform: add or remove (default "add")
  -agent string       agent name in poller.json (default "local-agent")
  -type string        service type (e.g., sysmon, rperf-checker, snmp)
  -name string        service name (defaults to service type)
  -details string     service details (e.g., IP:port for grpc)
  -enable-all         enable all standard checkers

Options for generate-tls:
  -ip string          IP addresses for the certificates (comma-separated)
  -cert-dir string    where to store ServiceRadar certificates (default "/etc/serviceradar/certs")
  -proton-dir string  where to store Proton certificates (default "/etc/proton-server")
  -add-ips            add IPs to existing certificates
  -non-interactive    run in non-interactive mode (use 127.0.0.1)

Examples:
  # Generate bcrypt hash
  serviceradar mypassword
  echo mypassword | serviceradar
  serviceradar  # launches TUI

  # Update core.json
  serviceradar update-config -file /etc/serviceradar/core.json -admin-hash '$2a$12$...'

  # Add a checker to poller.json
  serviceradar update-poller -file /etc/serviceradar/poller.json -type sysmon
  
  # Remove a checker from poller.json
  serviceradar update-poller -file /etc/serviceradar/poller.json -action remove -type sysmon
  
  # Enable all standard checkers
  serviceradar update-poller -file /etc/serviceradar/poller.json -enable-all

  # Generate mTLS certificates
  serviceradar generate-tls -ip 192.168.1.10,10.0.0.5
  serviceradar generate-tls --non-interactive
  serviceradar generate-tls --add-ips -ip 10.0.0.5

  # Request a join token and downstream registration from core
  serviceradar spire-join-token \
    -core-url https://core.demo.serviceradar.cloud \
    -api-key "$SERVICERADAR_API_KEY" \
    -downstream-spiffe-id spiffe://carverauto.dev/ns/demo/poller-nested-spire \
    -selector unix:uid:0 -selector unix:gid:0 \
    -selector unix:user:root -selector unix:path:/opt/spire/bin/spire-server

Options for render-kong:
  -jwks string       JWKS URL (default http://core:8090/auth/jwks.json)
  -service string    upstream service URL (default http://core:8090)
  -path string       route path prefix (default /api)
  -out string        output kong.yml path (default /etc/kong/kong.yml)
  -key-claim string  JWT key claim (default kid)

Example:
  serviceradar render-kong -jwks http://core:8090/auth/jwks.json -service http://core:8090 -path /api -out /etc/kong/kong.yml

Options for generate-jwt-keys:
  -file string       path to core.json (default /etc/serviceradar/config/core.json)
  -kid string        key id to embed in JWT header (default auto-derived)
  -bits int          RSA key size in bits (default 2048)
  -force             overwrite existing RS256 keys if present

Options for spire-join-token:
  -core-url string        Core API base URL (default http://localhost:8090)
  -api-key string         API key used to authenticate with core
  -bearer string          Bearer token used to authenticate with core
  -tls-skip-verify        Skip TLS certificate verification
  -ttl int                Join token TTL in seconds
  -agent-spiffe-id string Optional alias SPIFFE ID to assign to the agent
  -no-downstream          Do not register a downstream entry
  -downstream-spiffe-id string  SPIFFE ID for the downstream poller SPIRE server
  -selector value         Downstream selector (repeatable, e.g. k8s:ns:demo)
  -x509-ttl int           Downstream X.509 SVID TTL in seconds
  -jwt-ttl int            Downstream JWT SVID TTL in seconds
  -downstream-admin       Mark downstream entry as admin
  -downstream-store-svid  Request downstream SVID storage
  -dns-name value         Downstream DNS name (repeatable)
  -federates-with value   Downstream federated trust domain (repeatable)
  -output string          Write the response JSON to the given file path
`)
}
