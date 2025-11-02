package registry

import (
	"time"
)

// ServiceStatus represents the lifecycle status of a service.
type ServiceStatus string

const (
	ServiceStatusPending  ServiceStatus = "pending"  // Registered, waiting for first report
	ServiceStatusActive   ServiceStatus = "active"   // Currently reporting
	ServiceStatusInactive ServiceStatus = "inactive" // Stopped reporting
	ServiceStatusRevoked  ServiceStatus = "revoked"  // Registration revoked
	ServiceStatusDeleted  ServiceStatus = "deleted"  // Marked for deletion (soft delete)
)

// RegistrationSource indicates how a service was registered.
type RegistrationSource string

const (
	RegistrationSourceEdgeOnboarding RegistrationSource = "edge_onboarding"
	RegistrationSourceK8sSpiffe      RegistrationSource = "k8s_spiffe"
	RegistrationSourceConfig         RegistrationSource = "config"   // Static config file
	RegistrationSourceImplicit       RegistrationSource = "implicit" // From heartbeat
)

// PollerRegistration represents a poller registration request.
type PollerRegistration struct {
	PollerID           string
	ComponentID        string // From edge onboarding package
	RegistrationSource RegistrationSource
	Metadata           map[string]string
	SPIFFEIdentity     string // Optional SPIFFE ID
	CreatedBy          string // Admin user ID or system
}

// AgentRegistration represents an agent registration request.
type AgentRegistration struct {
	AgentID            string
	PollerID           string // Parent poller (required)
	ComponentID        string
	RegistrationSource RegistrationSource
	Metadata           map[string]string
	SPIFFEIdentity     string
	CreatedBy          string
}

// CheckerRegistration represents a checker registration request.
type CheckerRegistration struct {
	CheckerID          string
	AgentID            string // Parent agent (required)
	PollerID           string // Grandparent poller (denormalized for queries)
	CheckerKind        string // snmp, sysmon, rperf, etc.
	ComponentID        string
	RegistrationSource RegistrationSource
	Metadata           map[string]string
	SPIFFEIdentity     string
	CreatedBy          string
}

// ServiceHeartbeat represents a service status report.
type ServiceHeartbeat struct {
	ServiceID   string
	ServiceType string // "poller", "agent", "checker"
	PollerID    string
	AgentID     string // Empty for pollers
	CheckerID   string // Empty for agents/pollers
	Timestamp   time.Time
	SourceIP    string
	Healthy     bool
	Metadata    map[string]string
}

// RegisteredPoller represents a registered poller in the system.
type RegisteredPoller struct {
	PollerID           string
	ComponentID        string
	Status             ServiceStatus
	RegistrationSource RegistrationSource
	FirstRegistered    time.Time
	FirstSeen          *time.Time // Nil if never reported
	LastSeen           *time.Time
	Metadata           map[string]string
	SPIFFEIdentity     string
	CreatedBy          string

	// Derived stats
	AgentCount   int
	CheckerCount int
}

// RegisteredAgent represents a registered agent in the system.
type RegisteredAgent struct {
	AgentID            string
	PollerID           string
	ComponentID        string
	Status             ServiceStatus
	RegistrationSource RegistrationSource
	FirstRegistered    time.Time
	FirstSeen          *time.Time
	LastSeen           *time.Time
	Metadata           map[string]string
	SPIFFEIdentity     string
	CreatedBy          string

	// Derived stats
	CheckerCount int
}

// RegisteredChecker represents a registered checker in the system.
type RegisteredChecker struct {
	CheckerID          string
	AgentID            string
	PollerID           string
	CheckerKind        string
	ComponentID        string
	Status             ServiceStatus
	RegistrationSource RegistrationSource
	FirstRegistered    time.Time
	FirstSeen          *time.Time
	LastSeen           *time.Time
	Metadata           map[string]string
	SPIFFEIdentity     string
	CreatedBy          string
}

// ServiceFilter filters service queries.
type ServiceFilter struct {
	Statuses []ServiceStatus
	Sources  []RegistrationSource
	Limit    int
	Offset   int
}

// RegistrationEvent represents an audit event for service registration.
type RegistrationEvent struct {
	EventID            string
	EventType          string // 'registered', 'activated', 'deactivated', 'revoked', 'deleted'
	ServiceID          string
	ServiceType        string // 'poller', 'agent', 'checker'
	ParentID           string
	RegistrationSource RegistrationSource
	Actor              string
	Timestamp          time.Time
	Metadata           map[string]string
}
