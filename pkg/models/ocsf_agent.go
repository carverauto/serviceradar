/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package models

import (
	"encoding/json"
	"time"
)

// OCSF Agent Type IDs (aligned with OCSF v1.7.0)
// See: https://schema.ocsf.io/1.7.0/objects/agent
const (
	OCSFAgentTypeUnknown                     = 0
	OCSFAgentTypeEndpointDetectionResponse   = 1
	OCSFAgentTypeDataLossPrevention          = 2
	OCSFAgentTypeBackupRecovery              = 3
	OCSFAgentTypePerformanceMonitoring       = 4
	OCSFAgentTypeVulnerabilityManagement     = 5
	OCSFAgentTypeLogManagement               = 6
	OCSFAgentTypeMobileDeviceManagement      = 7
	OCSFAgentTypeConfigurationManagement     = 8
	OCSFAgentTypeRemoteAccess                = 9
	OCSFAgentTypeOther                       = 99
)

// Agent type name string constants
const (
	AgentTypeNameUnknown               = "Unknown"
	AgentTypeNameEDR                   = "Endpoint Detection and Response"
	AgentTypeNameDLP                   = "Data Loss Prevention"
	AgentTypeNameBackup                = "Backup and Recovery"
	AgentTypeNamePerformanceMonitoring = "Performance Monitoring and Observability"
	AgentTypeNameVulnerability         = "Vulnerability Management"
	AgentTypeNameLogManagement         = "Log Management"
	AgentTypeNameMDM                   = "Mobile Device Management"
	AgentTypeNameConfigManagement      = "Configuration Management"
	AgentTypeNameRemoteAccess          = "Remote Access"
	AgentTypeNameOther                 = "Other"
)

// GetAgentTypeName returns the human-readable name for an agent type ID.
func GetAgentTypeName(typeID int) string {
	switch typeID {
	case OCSFAgentTypeUnknown:
		return AgentTypeNameUnknown
	case OCSFAgentTypeEndpointDetectionResponse:
		return AgentTypeNameEDR
	case OCSFAgentTypeDataLossPrevention:
		return AgentTypeNameDLP
	case OCSFAgentTypeBackupRecovery:
		return AgentTypeNameBackup
	case OCSFAgentTypePerformanceMonitoring:
		return AgentTypeNamePerformanceMonitoring
	case OCSFAgentTypeVulnerabilityManagement:
		return AgentTypeNameVulnerability
	case OCSFAgentTypeLogManagement:
		return AgentTypeNameLogManagement
	case OCSFAgentTypeMobileDeviceManagement:
		return AgentTypeNameMDM
	case OCSFAgentTypeConfigurationManagement:
		return AgentTypeNameConfigManagement
	case OCSFAgentTypeRemoteAccess:
		return AgentTypeNameRemoteAccess
	case OCSFAgentTypeOther:
		return AgentTypeNameOther
	default:
		return AgentTypeNameUnknown
	}
}

// OCSFAgentPolicy represents a policy applied to an agent
type OCSFAgentPolicy struct {
	Name    string `json:"name,omitempty"`
	UID     string `json:"uid,omitempty"`
	Version string `json:"version,omitempty"`
}

// OCSFAgentRecord represents an agent record in the ocsf_agents table.
// This is the full database record with ServiceRadar extensions.
type OCSFAgentRecord struct {
	// OCSF Core Identity (per https://schema.ocsf.io/1.7.0/objects/agent)
	UID        string `json:"uid" db:"uid"`                       // Unique agent identifier (sensor ID)
	Name       string `json:"name,omitempty" db:"name"`           // Agent designation (e.g., "serviceradar-agent")
	TypeID     int    `json:"type_id" db:"type_id"`               // OCSF agent type enum
	Type       string `json:"type,omitempty" db:"type"`           // Human-readable agent type name

	// OCSF Extended Identity
	Version    string            `json:"version,omitempty" db:"version"`         // Semantic version of the agent
	VendorName string            `json:"vendor_name,omitempty" db:"vendor_name"` // Agent vendor (e.g., "ServiceRadar")
	UIDAlt     string            `json:"uid_alt,omitempty" db:"uid_alt"`         // Alternate unique identifier
	Policies   []OCSFAgentPolicy `json:"policies,omitempty" db:"policies"`       // Applied policies array

	// ServiceRadar Extensions
	PollerID      string    `json:"poller_id,omitempty" db:"poller_id"`           // Parent poller reference
	Capabilities  []string  `json:"capabilities,omitempty" db:"capabilities"`    // Registered checker capabilities
	IP            string    `json:"ip,omitempty" db:"ip"`                         // Agent IP address
	FirstSeenTime time.Time `json:"first_seen_time,omitempty" db:"first_seen_time"`
	LastSeenTime  time.Time `json:"last_seen_time,omitempty" db:"last_seen_time"`
	CreatedTime   time.Time `json:"created_time" db:"created_time"`
	ModifiedTime  time.Time `json:"modified_time" db:"modified_time"`
	Metadata      map[string]string `json:"metadata,omitempty" db:"metadata"`
}

// GetTypeName returns the human-readable name for the agent type
func (a *OCSFAgentRecord) GetTypeName() string {
	if a.Type != "" {
		return a.Type
	}
	return GetAgentTypeName(a.TypeID)
}

// ToOCSFAgent converts the full record to the embedded OCSFAgent format for device agent_list
func (a *OCSFAgentRecord) ToOCSFAgent() OCSFAgent {
	var typeID *int
	if a.TypeID != 0 {
		typeID = &a.TypeID
	}
	return OCSFAgent{
		UID:        a.UID,
		Name:       a.Name,
		Type:       a.GetTypeName(),
		TypeID:     typeID,
		Version:    a.Version,
		VendorName: a.VendorName,
	}
}

// ToJSONFields serializes nested objects to JSON for database storage
func (a *OCSFAgentRecord) ToJSONFields() (policiesJSON, metadataJSON []byte, err error) {
	if len(a.Policies) > 0 {
		policiesJSON, err = json.Marshal(a.Policies)
		if err != nil {
			return nil, nil, err
		}
	}

	if len(a.Metadata) > 0 {
		metadataJSON, err = json.Marshal(a.Metadata)
		if err != nil {
			return nil, nil, err
		}
	}

	return policiesJSON, metadataJSON, nil
}

// DetermineAgentTypeFromCapabilities determines the OCSF agent type based on capabilities
func DetermineAgentTypeFromCapabilities(capabilities []string) (int, string) {
	hasPerformance := false
	hasLog := false

	for _, cap := range capabilities {
		switch cap {
		case "icmp", "snmp", "rperf", "sysmon", "mapper":
			hasPerformance = true
		case "syslog", "netflow":
			hasLog = true
		}
	}

	// If agent has both performance and log capabilities, default to performance
	if hasPerformance {
		return OCSFAgentTypePerformanceMonitoring, AgentTypeNamePerformanceMonitoring
	}
	if hasLog {
		return OCSFAgentTypeLogManagement, AgentTypeNameLogManagement
	}

	return OCSFAgentTypeUnknown, AgentTypeNameUnknown
}

// NewOCSFAgentRecord creates a new OCSFAgentRecord with defaults set
func NewOCSFAgentRecord(uid, pollerID, ip string, capabilities []string) *OCSFAgentRecord {
	now := time.Now()
	typeID, typeName := DetermineAgentTypeFromCapabilities(capabilities)

	return &OCSFAgentRecord{
		UID:           uid,
		Name:          "serviceradar-agent",
		TypeID:        typeID,
		Type:          typeName,
		VendorName:    "ServiceRadar",
		PollerID:      pollerID,
		Capabilities:  capabilities,
		IP:            ip,
		FirstSeenTime: now,
		LastSeenTime:  now,
		CreatedTime:   now,
		ModifiedTime:  now,
	}
}

// CreateOCSFAgentFromRegistration creates an OCSFAgentRecord from registration data
func CreateOCSFAgentFromRegistration(agentID, pollerID, hostIP, version string, capabilities []string, metadata map[string]string) *OCSFAgentRecord {
	agent := NewOCSFAgentRecord(agentID, pollerID, hostIP, capabilities)

	if version != "" {
		agent.Version = version
	}

	if metadata != nil {
		agent.Metadata = metadata
	}

	return agent
}

// MergeCapabilities merges new capabilities into existing ones without duplicates
func (a *OCSFAgentRecord) MergeCapabilities(newCaps []string) {
	capSet := make(map[string]bool)
	for _, cap := range a.Capabilities {
		capSet[cap] = true
	}
	for _, cap := range newCaps {
		if !capSet[cap] {
			a.Capabilities = append(a.Capabilities, cap)
			capSet[cap] = true
		}
	}
	// Re-evaluate type based on updated capabilities
	a.TypeID, a.Type = DetermineAgentTypeFromCapabilities(a.Capabilities)
}

// UpdateHeartbeat updates the last seen time and optionally capabilities
func (a *OCSFAgentRecord) UpdateHeartbeat(ip string, capabilities []string) {
	a.LastSeenTime = time.Now()
	a.ModifiedTime = time.Now()
	if ip != "" {
		a.IP = ip
	}
	if len(capabilities) > 0 {
		a.MergeCapabilities(capabilities)
	}
}
