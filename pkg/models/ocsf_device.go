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

// Package models contains data models for ServiceRadar.
package models

import (
	"encoding/json"
	"time"
)

// OCSF Device Type IDs (aligned with OCSF v1.7.0)
const (
	OCSFDeviceTypeUnknown      = 0
	OCSFDeviceTypeServer       = 1
	OCSFDeviceTypeDesktop      = 2
	OCSFDeviceTypeLaptop       = 3
	OCSFDeviceTypeTablet       = 4
	OCSFDeviceTypeMobile       = 5
	OCSFDeviceTypeVirtual      = 6
	OCSFDeviceTypeIOT          = 7
	OCSFDeviceTypeBrowser      = 8
	OCSFDeviceTypeFirewall     = 9
	OCSFDeviceTypeSwitch       = 10
	OCSFDeviceTypeHub          = 11
	OCSFDeviceTypeRouter       = 12
	OCSFDeviceTypeIDS          = 13
	OCSFDeviceTypeIPS          = 14
	OCSFDeviceTypeLoadBalancer = 15
	OCSFDeviceTypeOther        = 99
)

// OCSFDeviceTypeNames maps type IDs to human-readable names
var OCSFDeviceTypeNames = map[int]string{
	OCSFDeviceTypeUnknown:      "Unknown",
	OCSFDeviceTypeServer:       "Server",
	OCSFDeviceTypeDesktop:      "Desktop",
	OCSFDeviceTypeLaptop:       "Laptop",
	OCSFDeviceTypeTablet:       "Tablet",
	OCSFDeviceTypeMobile:       "Mobile",
	OCSFDeviceTypeVirtual:      "Virtual",
	OCSFDeviceTypeIOT:          "IOT",
	OCSFDeviceTypeBrowser:      "Browser",
	OCSFDeviceTypeFirewall:     "Firewall",
	OCSFDeviceTypeSwitch:       "Switch",
	OCSFDeviceTypeHub:          "Hub",
	OCSFDeviceTypeRouter:       "Router",
	OCSFDeviceTypeIDS:          "IDS",
	OCSFDeviceTypeIPS:          "IPS",
	OCSFDeviceTypeLoadBalancer: "Load Balancer",
	OCSFDeviceTypeOther:        "Other",
}

// OCSF Risk Level IDs
const (
	OCSFRiskLevelInfo     = 0
	OCSFRiskLevelLow      = 1
	OCSFRiskLevelMedium   = 2
	OCSFRiskLevelHigh     = 3
	OCSFRiskLevelCritical = 4
	OCSFRiskLevelOther    = 99
)

// OCSFRiskLevelNames maps risk level IDs to names
var OCSFRiskLevelNames = map[int]string{
	OCSFRiskLevelInfo:     "Info",
	OCSFRiskLevelLow:      "Low",
	OCSFRiskLevelMedium:   "Medium",
	OCSFRiskLevelHigh:     "High",
	OCSFRiskLevelCritical: "Critical",
	OCSFRiskLevelOther:    "Other",
}

// OCSFDevice represents a device aligned with OCSF v1.7.0 Device object schema
type OCSFDevice struct {
	// OCSF Core Identity
	UID      string `json:"uid" db:"uid"`                // Canonical device ID from DIRE (sr: prefixed UUID)
	TypeID   int    `json:"type_id" db:"type_id"`        // OCSF device type enum
	Type     string `json:"type,omitempty" db:"type"`    // Human-readable device type name
	Name     string `json:"name,omitempty" db:"name"`    // Administrator-assigned device name
	Hostname string `json:"hostname,omitempty" db:"hostname"`
	IP       string `json:"ip,omitempty" db:"ip"`
	MAC      string `json:"mac,omitempty" db:"mac"`

	// OCSF Extended Identity
	UIDAlt     string `json:"uid_alt,omitempty" db:"uid_alt"`         // Alternate unique identifier
	VendorName string `json:"vendor_name,omitempty" db:"vendor_name"` // Device manufacturer
	Model      string `json:"model,omitempty" db:"model"`             // Device model
	Domain     string `json:"domain,omitempty" db:"domain"`           // Network domain
	Zone       string `json:"zone,omitempty" db:"zone"`               // Network zone
	SubnetUID  string `json:"subnet_uid,omitempty" db:"subnet_uid"`   // Subnet identifier
	VlanUID    string `json:"vlan_uid,omitempty" db:"vlan_uid"`       // VLAN identifier
	Region     string `json:"region,omitempty" db:"region"`           // Geographic region

	// OCSF Temporal
	FirstSeenTime *time.Time `json:"first_seen_time,omitempty" db:"first_seen_time"`
	LastSeenTime  *time.Time `json:"last_seen_time,omitempty" db:"last_seen_time"`
	CreatedTime   time.Time  `json:"created_time" db:"created_time"`
	ModifiedTime  time.Time  `json:"modified_time" db:"modified_time"`

	// OCSF Risk and Compliance
	RiskLevelID *int   `json:"risk_level_id,omitempty" db:"risk_level_id"`
	RiskLevel   string `json:"risk_level,omitempty" db:"risk_level"`
	RiskScore   *int   `json:"risk_score,omitempty" db:"risk_score"`
	IsManaged   *bool  `json:"is_managed,omitempty" db:"is_managed"`
	IsCompliant *bool  `json:"is_compliant,omitempty" db:"is_compliant"`
	IsTrusted   *bool  `json:"is_trusted,omitempty" db:"is_trusted"`

	// OCSF Nested Objects (stored as JSONB in DB)
	OS                *OCSFDeviceOS           `json:"os,omitempty" db:"os"`
	HWInfo            *OCSFDeviceHWInfo       `json:"hw_info,omitempty" db:"hw_info"`
	NetworkInterfaces []OCSFNetworkInterface  `json:"network_interfaces,omitempty" db:"network_interfaces"`
	Owner             *OCSFUser               `json:"owner,omitempty" db:"owner"`
	Org               *OCSFOrganization       `json:"org,omitempty" db:"org"`
	Groups            []OCSFGroup             `json:"groups,omitempty" db:"groups"`
	AgentList         []OCSFAgent             `json:"agent_list,omitempty" db:"agent_list"`

	// ServiceRadar-specific fields
	PollerID         string            `json:"poller_id,omitempty" db:"poller_id"`
	AgentID          string            `json:"agent_id,omitempty" db:"agent_id"`
	DiscoverySources []string          `json:"discovery_sources,omitempty" db:"discovery_sources"`
	IsAvailable      *bool             `json:"is_available,omitempty" db:"is_available"`
	Metadata         map[string]string `json:"metadata,omitempty" db:"metadata"`
}

// OCSFDeviceOS represents the operating system information
type OCSFDeviceOS struct {
	Name          string `json:"name,omitempty"`
	Type          string `json:"type,omitempty"`           // OS family (Windows, Linux, macOS)
	TypeID        *int   `json:"type_id,omitempty"`        // OCSF OS type enum
	Version       string `json:"version,omitempty"`        // OS version string
	Build         string `json:"build,omitempty"`          // OS build number
	Edition       string `json:"edition,omitempty"`        // OS edition (Enterprise, Pro)
	KernelRelease string `json:"kernel_release,omitempty"` // Kernel version for Linux/Unix
	CPUBits       *int   `json:"cpu_bits,omitempty"`       // Architecture bits (32 or 64)
	SPName        string `json:"sp_name,omitempty"`        // Service pack name
	SPVer         string `json:"sp_ver,omitempty"`         // Service pack version
	Lang          string `json:"lang,omitempty"`           // OS language
}

// OCSFDeviceHWInfo represents hardware information
type OCSFDeviceHWInfo struct {
	CPUArchitecture  string  `json:"cpu_architecture,omitempty"`   // CPU architecture (x86_64, arm64)
	CPUBits          *int    `json:"cpu_bits,omitempty"`           // CPU bits (32 or 64)
	CPUCores         *int    `json:"cpu_cores,omitempty"`          // Number of CPU cores
	CPUCount         *int    `json:"cpu_count,omitempty"`          // Number of physical CPUs
	CPUSpeedMhz      *int    `json:"cpu_speed_mhz,omitempty"`      // CPU speed in MHz
	CPUType          string  `json:"cpu_type,omitempty"`           // CPU model name
	RAMSize          *int64  `json:"ram_size,omitempty"`           // Total RAM in bytes
	SerialNumber     string  `json:"serial_number,omitempty"`      // Device serial number
	Chassis          string  `json:"chassis,omitempty"`            // Chassis type
	BIOSManufacturer string  `json:"bios_manufacturer,omitempty"`  // BIOS manufacturer
	BIOSVer          string  `json:"bios_ver,omitempty"`           // BIOS version
	BIOSDate         string  `json:"bios_date,omitempty"`          // BIOS release date
	UUID             string  `json:"uuid,omitempty"`               // Hardware UUID
}

// OCSFNetworkInterface represents a network interface
type OCSFNetworkInterface struct {
	MAC      string `json:"mac,omitempty"`
	IP       string `json:"ip,omitempty"`
	Hostname string `json:"hostname,omitempty"`
	Name     string `json:"name,omitempty"`     // Interface name (eth0, ens192)
	UID      string `json:"uid,omitempty"`      // Interface unique identifier
	Type     string `json:"type,omitempty"`     // Interface type name
	TypeID   *int   `json:"type_id,omitempty"`  // OCSF interface type enum
}

// OCSFUser represents a user or owner
type OCSFUser struct {
	UID    string `json:"uid,omitempty"`
	Name   string `json:"name,omitempty"`
	Email  string `json:"email,omitempty"`
	Type   string `json:"type,omitempty"`
	TypeID *int   `json:"type_id,omitempty"`
}

// OCSFOrganization represents an organization
type OCSFOrganization struct {
	UID    string `json:"uid,omitempty"`
	Name   string `json:"name,omitempty"`
	OUUid  string `json:"ou_uid,omitempty"`
	OUName string `json:"ou_name,omitempty"`
}

// OCSFGroup represents a device group
type OCSFGroup struct {
	UID  string `json:"uid,omitempty"`
	Name string `json:"name,omitempty"`
	Type string `json:"type,omitempty"`
	Desc string `json:"desc,omitempty"`
}

// OCSFAgent represents an agent installed on the device
type OCSFAgent struct {
	UID        string `json:"uid,omitempty"`
	Name       string `json:"name,omitempty"`
	Type       string `json:"type,omitempty"`
	TypeID     *int   `json:"type_id,omitempty"`
	Version    string `json:"version,omitempty"`
	VendorName string `json:"vendor_name,omitempty"`
}

// GetTypeName returns the human-readable name for the device type
func (d *OCSFDevice) GetTypeName() string {
	if d.Type != "" {
		return d.Type
	}
	if name, ok := OCSFDeviceTypeNames[d.TypeID]; ok {
		return name
	}
	return "Unknown"
}

// GetRiskLevelName returns the human-readable name for the risk level
func (d *OCSFDevice) GetRiskLevelName() string {
	if d.RiskLevel != "" {
		return d.RiskLevel
	}
	if d.RiskLevelID != nil {
		if name, ok := OCSFRiskLevelNames[*d.RiskLevelID]; ok {
			return name
		}
	}
	return ""
}

// RiskLevelFromScore derives the OCSF risk level from a numeric score (0-100)
func RiskLevelFromScore(score int) (int, string) {
	switch {
	case score <= 20:
		return OCSFRiskLevelInfo, "Info"
	case score <= 40:
		return OCSFRiskLevelLow, "Low"
	case score <= 60:
		return OCSFRiskLevelMedium, "Medium"
	case score <= 80:
		return OCSFRiskLevelHigh, "High"
	default:
		return OCSFRiskLevelCritical, "Critical"
	}
}

// NewOCSFDeviceFromUpdate creates a new OCSFDevice from a DeviceUpdate
func NewOCSFDeviceFromUpdate(update *DeviceUpdate) *OCSFDevice {
	now := update.Timestamp
	if now.IsZero() {
		now = time.Now()
	}

	device := &OCSFDevice{
		UID:          update.DeviceID,
		TypeID:       OCSFDeviceTypeUnknown,
		Type:         "Unknown",
		IP:           update.IP,
		CreatedTime:  now,
		ModifiedTime: now,
		FirstSeenTime: &now,
		LastSeenTime:  &now,
		PollerID:     update.PollerID,
		AgentID:      update.AgentID,
		DiscoverySources: []string{string(update.Source)},
		IsAvailable:  &update.IsAvailable,
	}

	if update.Hostname != nil {
		device.Hostname = *update.Hostname
	}

	if update.MAC != nil {
		device.MAC = *update.MAC
	}

	if len(update.Metadata) > 0 {
		device.Metadata = update.Metadata
	}

	return device
}

// ToJSON serializes nested objects to JSON for database storage
func (d *OCSFDevice) ToJSONFields() (osJSON, hwInfoJSON, networkInterfacesJSON, ownerJSON, orgJSON, groupsJSON, agentListJSON, metadataJSON []byte, err error) {
	if d.OS != nil {
		osJSON, err = json.Marshal(d.OS)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, nil, nil, err
		}
	}

	if d.HWInfo != nil {
		hwInfoJSON, err = json.Marshal(d.HWInfo)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, nil, nil, err
		}
	}

	if len(d.NetworkInterfaces) > 0 {
		networkInterfacesJSON, err = json.Marshal(d.NetworkInterfaces)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, nil, nil, err
		}
	}

	if d.Owner != nil {
		ownerJSON, err = json.Marshal(d.Owner)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, nil, nil, err
		}
	}

	if d.Org != nil {
		orgJSON, err = json.Marshal(d.Org)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, nil, nil, err
		}
	}

	if len(d.Groups) > 0 {
		groupsJSON, err = json.Marshal(d.Groups)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, nil, nil, err
		}
	}

	if len(d.AgentList) > 0 {
		agentListJSON, err = json.Marshal(d.AgentList)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, nil, nil, err
		}
	}

	if len(d.Metadata) > 0 {
		metadataJSON, err = json.Marshal(d.Metadata)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, nil, nil, err
		}
	}

	return osJSON, hwInfoJSON, networkInterfacesJSON, ownerJSON, orgJSON, groupsJSON, agentListJSON, metadataJSON, nil
}
