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
  edge package create  Issue a new onboarding package and emit the structured token
  edge package list    List onboarding packages with optional filters
  edge package show    Display detailed information for a package
  edge package download Download onboarding artifacts (tar.gz or JSON)
  edge package revoke  Revoke an onboarding package (alias: edge-package-revoke)
  edge package token   Emit an edgepkg-v1 token (alias: edge-package-token)
  edge-package-download Download the onboarding archive for a package (tar.gz)
  edge-package-token    Emit an edgepkg-v1 onboarding token for ONBOARDING_TOKEN
  edge-package-revoke   Revoke an onboarding package and downstream entry

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

Options for edge-package-download:
  -core-url string        Core API base URL (default http://localhost:8090)
  -api-key string         API key used to authenticate with core
  -bearer string          Bearer token used to authenticate with core
  -tls-skip-verify        Skip TLS certificate verification
  -id string              Edge package identifier
  -download-token string  Edge package download token
  -output string          Optional file path for writing the onboarding archive
  -format string          Download format: tar or json (default "tar")

Options for edge-package-token:
  -core-url string        Core API base URL (default http://localhost:8090)
  -id string              Edge package identifier
  -download-token string  Edge package download token

Options for edge-package-revoke:
  -core-url string        Core API base URL (default http://localhost:8090)
  -api-key string         API key used to authenticate with core
  -bearer string          Bearer token used to authenticate with core
  -tls-skip-verify        Skip TLS certificate verification
  -id string              Edge package identifier
  -reason string          Optional revocation reason

Options for edge package create:
  --core-url string            Core API base URL (default http://localhost:8090)
  --api-key string             API key used to authenticate with core
  --bearer string              Bearer token used to authenticate with core
  --tls-skip-verify            Skip TLS certificate verification
  --label string               Display label for the package (required)
  --component-type string      Component type (poller, agent, checker[:kind], default poller)
  --component-id string        Optional component identifier override
  --parent-type string         Parent component type (poller, agent, checker)
  --parent-id string           Parent identifier
  --poller-id string           Poller identifier override
  --site string                Site/location note
  --metadata-json string       Metadata JSON payload
  --metadata-file string       Path to metadata JSON file (alternative to --metadata-json)
  --selector value             SPIRE selector (repeatable, e.g. unix:uid:0)
  --join-ttl duration          Join token TTL (e.g., 30m, 2h)
  --download-ttl duration      Download token TTL (e.g., 15m, 24h)
  --downstream-spiffe-id string Downstream SPIFFE ID override
  --datasvc-endpoint string    Datasvc/KV gRPC endpoint override
  --checker-kind string        Checker kind (when component-type checker)
  --checker-config-json string Checker configuration JSON
  --output string              Output format: text or json (default text)

Options for edge package list:
  --core-url string        Core API base URL (default http://localhost:8090)
  --api-key string         API key used to authenticate with core
  --bearer string          Bearer token used to authenticate with core
  --tls-skip-verify        Skip TLS certificate verification
  --limit int              Maximum number of packages to return (default 50)
  --status value           Filter by status (repeatable)
  --component-type value   Filter by component type (repeatable)
  --poller-id string       Filter by poller identifier
  --parent-id string       Filter by parent identifier
  --component-id string    Filter by component identifier
  --output string          Output format: text or json (default text)

Options for edge package show:
  --core-url string        Core API base URL (default http://localhost:8090)
  --api-key string         API key used to authenticate with core
  --bearer string          Bearer token used to authenticate with core
  --tls-skip-verify        Skip TLS certificate verification
  --id string              Edge package identifier (required)
  --output string          Output format: text or json (default text)
  --reissue-token          Emit an edgepkg-v1 token using --download-token
  --download-token string  Download token to encode when --reissue-token is set
`)
}
