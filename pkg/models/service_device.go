package models

import "fmt"

// ServiceType represents the type of service component
type ServiceType string

const (
	// ServiceTypeGateway represents a gateway service
	ServiceTypeGateway ServiceType = "gateway"
	// ServiceTypeAgent represents an agent service
	ServiceTypeAgent ServiceType = "agent"
	// ServiceTypeChecker represents a checker service
	ServiceTypeChecker ServiceType = "checker"
	// ServiceTypeNetworkDevice represents a discovered network device (not a service component)
	ServiceTypeNetworkDevice ServiceType = "network"
	// ServiceTypeDatasvc represents the datasvc/KV service
	ServiceTypeDatasvc ServiceType = "datasvc"
	// ServiceTypeKV is an alias for datasvc (legacy name)
	ServiceTypeKV ServiceType = "kv"
	// ServiceTypeSync represents the sync service
	ServiceTypeSync ServiceType = "sync"
	// ServiceTypeMapper represents the mapper service
	ServiceTypeMapper ServiceType = "mapper"
	// ServiceTypeOtel represents the OpenTelemetry collector service
	ServiceTypeOtel ServiceType = "otel"
	// ServiceTypeZen represents the zen service
	ServiceTypeZen ServiceType = "zen"
	// ServiceTypeCore represents the core service
	ServiceTypeCore ServiceType = "core"
)

// ServiceDevicePartition is the special partition used for service components
const ServiceDevicePartition = "serviceradar"

// GenerateServiceDeviceID creates a device ID for a service component
// Format: serviceradar:service_type:service_id
// Example: serviceradar:gateway:k8s-gateway
func GenerateServiceDeviceID(serviceType ServiceType, serviceID string) string {
	return fmt.Sprintf("%s:%s:%s", ServiceDevicePartition, serviceType, serviceID)
}

// GenerateNetworkDeviceID creates a device ID for a discovered network device
// Format: partition:ip
// Example: default:192.168.1.1
func GenerateNetworkDeviceID(partition, ip string) string {
	if partition == "" {
		partition = "default"
	}
	return fmt.Sprintf("%s:%s", partition, ip)
}

// IsServiceDevice checks if a device_id represents a service component
func IsServiceDevice(deviceID string) bool {
	// Service device IDs start with "serviceradar:"
	return len(deviceID) > len(ServiceDevicePartition) &&
		deviceID[:len(ServiceDevicePartition)] == ServiceDevicePartition
}
