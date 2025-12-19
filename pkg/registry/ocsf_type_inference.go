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

package registry

import (
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

// OCSFTypeInference provides methods to infer OCSF device type from discovery metadata
type OCSFTypeInference struct{}

// NewOCSFTypeInference creates a new type inference instance
func NewOCSFTypeInference() *OCSFTypeInference {
	return &OCSFTypeInference{}
}

// InferTypeID infers the OCSF device type_id from metadata
// Returns (type_id, type_name)
func (i *OCSFTypeInference) InferTypeID(metadata map[string]string) (int, string) {
	if metadata == nil {
		return models.OCSFDeviceTypeUnknown, "Unknown"
	}

	// Check for explicit type from Armis
	if armisCategory := metadata["armis_category"]; armisCategory != "" {
		if typeID, typeName := i.inferFromArmisCategory(armisCategory); typeID != models.OCSFDeviceTypeUnknown {
			return typeID, typeName
		}
	}

	// Check for device type from source system
	if deviceType := metadata["device_type"]; deviceType != "" {
		if typeID, typeName := i.inferFromDeviceType(deviceType); typeID != models.OCSFDeviceTypeUnknown {
			return typeID, typeName
		}
	}

	// Check SNMP sysDescr for network device hints
	if sysDescr := metadata["snmp_sys_descr"]; sysDescr != "" {
		if typeID, typeName := i.inferFromSNMPSysDescr(sysDescr); typeID != models.OCSFDeviceTypeUnknown {
			return typeID, typeName
		}
	}

	// Check for NetBox device role
	if netboxRole := metadata["netbox_role"]; netboxRole != "" {
		if typeID, typeName := i.inferFromNetboxRole(netboxRole); typeID != models.OCSFDeviceTypeUnknown {
			return typeID, typeName
		}
	}

	// Check for OS hints
	if osType := metadata["os_type"]; osType != "" {
		if typeID, typeName := i.inferFromOSType(osType); typeID != models.OCSFDeviceTypeUnknown {
			return typeID, typeName
		}
	}

	// Check for ServiceRadar component type
	if serviceType := metadata["service_type"]; serviceType != "" {
		if typeID, typeName := i.inferFromServiceType(serviceType); typeID != models.OCSFDeviceTypeUnknown {
			return typeID, typeName
		}
	}

	return models.OCSFDeviceTypeUnknown, "Unknown"
}

// inferFromArmisCategory maps Armis device categories to OCSF types
func (i *OCSFTypeInference) inferFromArmisCategory(category string) (int, string) {
	categoryLower := strings.ToLower(category)

	switch {
	case strings.Contains(categoryLower, "firewall"):
		return models.OCSFDeviceTypeFirewall, models.DeviceTypeNameFirewall
	case strings.Contains(categoryLower, "router"):
		return models.OCSFDeviceTypeRouter, models.DeviceTypeNameRouter
	case strings.Contains(categoryLower, "switch"):
		return models.OCSFDeviceTypeSwitch, models.DeviceTypeNameSwitch
	case strings.Contains(categoryLower, "server"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	case strings.Contains(categoryLower, "desktop"):
		return models.OCSFDeviceTypeDesktop, models.DeviceTypeNameDesktop
	case strings.Contains(categoryLower, "laptop"):
		return models.OCSFDeviceTypeLaptop, "Laptop"
	case strings.Contains(categoryLower, "tablet"):
		return models.OCSFDeviceTypeTablet, "Tablet"
	case strings.Contains(categoryLower, "mobile"), strings.Contains(categoryLower, "phone"):
		return models.OCSFDeviceTypeMobile, models.DeviceTypeNameMobile
	case strings.Contains(categoryLower, "iot"), strings.Contains(categoryLower, "sensor"),
		strings.Contains(categoryLower, "camera"), strings.Contains(categoryLower, "hvac"),
		strings.Contains(categoryLower, "smart"):
		return models.OCSFDeviceTypeIOT, "IOT"
	case strings.Contains(categoryLower, "virtual"), strings.Contains(categoryLower, "vm"):
		return models.OCSFDeviceTypeVirtual, "Virtual"
	case strings.Contains(categoryLower, "ids"):
		return models.OCSFDeviceTypeIDS, "IDS"
	case strings.Contains(categoryLower, "ips"):
		return models.OCSFDeviceTypeIPS, "IPS"
	case strings.Contains(categoryLower, "load balancer"), strings.Contains(categoryLower, "lb"):
		return models.OCSFDeviceTypeLoadBalancer, "Load Balancer"
	}

	return models.OCSFDeviceTypeUnknown, ""
}

// inferFromDeviceType maps generic device type strings to OCSF types
func (i *OCSFTypeInference) inferFromDeviceType(deviceType string) (int, string) {
	typeLower := strings.ToLower(deviceType)

	switch typeLower {
	case "server":
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	case "desktop", "workstation":
		return models.OCSFDeviceTypeDesktop, models.DeviceTypeNameDesktop
	case "laptop", "notebook":
		return models.OCSFDeviceTypeLaptop, "Laptop"
	case "router":
		return models.OCSFDeviceTypeRouter, models.DeviceTypeNameRouter
	case "switch":
		return models.OCSFDeviceTypeSwitch, models.DeviceTypeNameSwitch
	case "firewall":
		return models.OCSFDeviceTypeFirewall, models.DeviceTypeNameFirewall
	case "iot", "sensor":
		return models.OCSFDeviceTypeIOT, "IOT"
	case "virtual", "vm":
		return models.OCSFDeviceTypeVirtual, "Virtual"
	case "mobile", "phone":
		return models.OCSFDeviceTypeMobile, models.DeviceTypeNameMobile
	case "tablet":
		return models.OCSFDeviceTypeTablet, "Tablet"
	case "network_device":
		// Generic network device - need more info
		return models.OCSFDeviceTypeUnknown, ""
	}

	return models.OCSFDeviceTypeUnknown, ""
}

// inferFromSNMPSysDescr extracts device type from SNMP sysDescr
func (i *OCSFTypeInference) inferFromSNMPSysDescr(sysDescr string) (int, string) {
	sysDescrLower := strings.ToLower(sysDescr)

	// Cisco device detection
	if strings.Contains(sysDescrLower, "cisco") {
		switch {
		case strings.Contains(sysDescrLower, "router") || strings.Contains(sysDescrLower, "ios"):
			return models.OCSFDeviceTypeRouter, models.DeviceTypeNameRouter
		case strings.Contains(sysDescrLower, "switch") || strings.Contains(sysDescrLower, "catalyst"):
			return models.OCSFDeviceTypeSwitch, models.DeviceTypeNameSwitch
		case strings.Contains(sysDescrLower, "asa") || strings.Contains(sysDescrLower, "firewall"):
			return models.OCSFDeviceTypeFirewall, models.DeviceTypeNameFirewall
		}
	}

	// Juniper device detection
	if strings.Contains(sysDescrLower, "juniper") || strings.Contains(sysDescrLower, "junos") {
		switch {
		case strings.Contains(sysDescrLower, "router") || strings.Contains(sysDescrLower, "mx"):
			return models.OCSFDeviceTypeRouter, models.DeviceTypeNameRouter
		case strings.Contains(sysDescrLower, "switch") || strings.Contains(sysDescrLower, "ex"):
			return models.OCSFDeviceTypeSwitch, models.DeviceTypeNameSwitch
		case strings.Contains(sysDescrLower, "srx") || strings.Contains(sysDescrLower, "firewall"):
			return models.OCSFDeviceTypeFirewall, models.DeviceTypeNameFirewall
		}
	}

	// Generic network device detection
	switch {
	case strings.Contains(sysDescrLower, "router"):
		return models.OCSFDeviceTypeRouter, models.DeviceTypeNameRouter
	case strings.Contains(sysDescrLower, "switch"):
		return models.OCSFDeviceTypeSwitch, models.DeviceTypeNameSwitch
	case strings.Contains(sysDescrLower, "firewall"):
		return models.OCSFDeviceTypeFirewall, models.DeviceTypeNameFirewall
	case strings.Contains(sysDescrLower, "linux"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	case strings.Contains(sysDescrLower, "windows"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	}

	return models.OCSFDeviceTypeUnknown, ""
}

// inferFromNetboxRole maps NetBox device roles to OCSF types
func (i *OCSFTypeInference) inferFromNetboxRole(role string) (int, string) {
	roleLower := strings.ToLower(role)

	switch {
	case strings.Contains(roleLower, "router"):
		return models.OCSFDeviceTypeRouter, models.DeviceTypeNameRouter
	case strings.Contains(roleLower, "switch"):
		return models.OCSFDeviceTypeSwitch, models.DeviceTypeNameSwitch
	case strings.Contains(roleLower, "firewall"):
		return models.OCSFDeviceTypeFirewall, models.DeviceTypeNameFirewall
	case strings.Contains(roleLower, "server"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	case strings.Contains(roleLower, "load balancer"), strings.Contains(roleLower, "lb"):
		return models.OCSFDeviceTypeLoadBalancer, "Load Balancer"
	}

	return models.OCSFDeviceTypeUnknown, ""
}

// inferFromOSType maps OS types to likely device types
func (i *OCSFTypeInference) inferFromOSType(osType string) (int, string) {
	osTypeLower := strings.ToLower(osType)

	switch {
	case strings.Contains(osTypeLower, "ios"), strings.Contains(osTypeLower, "android"):
		return models.OCSFDeviceTypeMobile, models.DeviceTypeNameMobile
	case strings.Contains(osTypeLower, "macos"), strings.Contains(osTypeLower, "mac os"):
		return models.OCSFDeviceTypeDesktop, models.DeviceTypeNameDesktop
	case strings.Contains(osTypeLower, "windows server"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	case strings.Contains(osTypeLower, "windows"):
		return models.OCSFDeviceTypeDesktop, models.DeviceTypeNameDesktop
	case strings.Contains(osTypeLower, "linux") && strings.Contains(osTypeLower, "server"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	case strings.Contains(osTypeLower, "esxi"), strings.Contains(osTypeLower, "hypervisor"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	}

	return models.OCSFDeviceTypeUnknown, ""
}

// inferFromServiceType maps ServiceRadar service types to OCSF types
func (i *OCSFTypeInference) inferFromServiceType(serviceType string) (int, string) {
	serviceTypeLower := strings.ToLower(serviceType)

	// ServiceRadar infrastructure components are typically servers/virtual machines
	switch {
	case strings.Contains(serviceTypeLower, "poller"),
		strings.Contains(serviceTypeLower, "agent"),
		strings.Contains(serviceTypeLower, "core"),
		strings.Contains(serviceTypeLower, "checker"):
		// ServiceRadar components are typically running on servers/VMs
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	}

	return models.OCSFDeviceTypeUnknown, ""
}

// ExtractOSInfo extracts OS information from metadata into an OCSFDeviceOS struct
func (i *OCSFTypeInference) ExtractOSInfo(metadata map[string]string) *models.OCSFDeviceOS {
	if metadata == nil {
		return nil
	}

	os := &models.OCSFDeviceOS{}
	hasData := false

	if v := metadata["os_name"]; v != "" {
		os.Name = v
		hasData = true
	}
	if v := metadata["os_type"]; v != "" {
		os.Type = v
		hasData = true
	}
	if v := metadata["os_version"]; v != "" {
		os.Version = v
		hasData = true
	}
	if v := metadata["os_build"]; v != "" {
		os.Build = v
		hasData = true
	}
	if v := metadata["os_edition"]; v != "" {
		os.Edition = v
		hasData = true
	}
	if v := metadata["kernel_release"]; v != "" {
		os.KernelRelease = v
		hasData = true
	}

	if !hasData {
		return nil
	}
	return os
}

// ExtractHWInfo extracts hardware information from metadata into an OCSFDeviceHWInfo struct
func (i *OCSFTypeInference) ExtractHWInfo(metadata map[string]string) *models.OCSFDeviceHWInfo {
	if metadata == nil {
		return nil
	}

	hw := &models.OCSFDeviceHWInfo{}
	hasData := false

	if v := metadata["cpu_architecture"]; v != "" {
		hw.CPUArchitecture = v
		hasData = true
	}
	if v := metadata["cpu_type"]; v != "" {
		hw.CPUType = v
		hasData = true
	}
	if v := metadata["serial_number"]; v != "" {
		hw.SerialNumber = v
		hasData = true
	}
	if v := metadata["chassis"]; v != "" {
		hw.Chassis = v
		hasData = true
	}
	if v := metadata["hw_uuid"]; v != "" {
		hw.UUID = v
		hasData = true
	}
	if v := metadata["vendor"]; v != "" || metadata["manufacturer"] != "" {
		hw.BIOSManufacturer = v
		if hw.BIOSManufacturer == "" {
			hw.BIOSManufacturer = metadata["manufacturer"]
		}
		hasData = true
	}

	if !hasData {
		return nil
	}
	return hw
}

// ExtractVendorAndModel extracts vendor and model from metadata
func (i *OCSFTypeInference) ExtractVendorAndModel(metadata map[string]string) (vendor, model string) {
	if metadata == nil {
		return "", ""
	}

	// Try different metadata keys for vendor
	vendor = metadata["vendor"]
	if vendor == "" {
		vendor = metadata["manufacturer"]
	}
	if vendor == "" {
		vendor = metadata["armis_manufacturer"]
	}

	// Try different metadata keys for model
	model = metadata["model"]
	if model == "" {
		model = metadata["armis_model"]
	}

	return vendor, model
}
