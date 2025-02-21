package models

// ServerConfig holds the agent server configuration.
type ServerConfig struct {
	ListenAddr string          `json:"listen_addr"`
	Security   *SecurityConfig `json:"security"`
}

type ServiceRole string

const (
	RolePoller  ServiceRole = "poller"  // Client and Server
	RoleAgent   ServiceRole = "agent"   // Server only
	RoleCloud   ServiceRole = "cloud"   // Server only
	RoleChecker ServiceRole = "checker" // Server only (for SNMP, Dusk checkers)
)

// SecurityConfig holds common security configuration.
type SecurityConfig struct {
	Mode           SecurityMode `json:"mode"`
	CertDir        string       `json:"cert_dir"`
	ServerName     string       `json:"server_name,omitempty"`
	Role           ServiceRole  `json:"role"`
	TrustDomain    string       `json:"trust_domain,omitempty"`    // For SPIFFE
	WorkloadSocket string       `json:"workload_socket,omitempty"` // For SPIFFE
}

// SecurityMode defines the type of security to use.
type SecurityMode string
