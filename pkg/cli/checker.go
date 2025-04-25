package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// isGRPCService determines if a service type is actually implemented as a gRPC service.
func isGRPCService(serviceType string) bool {
	// List of service types that are implemented as gRPC services
	grpcServices := map[string]bool{
		"sysmon":        true,
		"dusk":          true,
		"rperf-checker": true,
		"snmp":          true,
	}

	return grpcServices[serviceType]
}

// addChecker adds a service check to the specified agent in the poller configuration.
func addChecker(pollerFile, agentName, serviceType, serviceName, details string, port int32) error {
	config, err := readPollerConfig(pollerFile)
	if err != nil {
		return err
	}

	agent, exists := config.Agents[agentName]
	if !exists {
		return fmt.Errorf("%w: %s", errAgentNotFound, agentName)
	}

	updatedAgent, isUpdate := addOrUpdateCheck(agent, serviceType, serviceName, details, port)
	config.Agents[agentName] = updatedAgent

	// Print appropriate message based on whether the check was added or updated
	action := "Added"
	if isUpdate {
		action = "Updated existing"
	}

	fmt.Printf("%s checker: %s/%s\n",
		action,
		updatedAgent.Checks[len(updatedAgent.Checks)-1].ServiceType,
		updatedAgent.Checks[len(updatedAgent.Checks)-1].ServiceName,
	)

	return writePollerConfig(pollerFile, config)
}

// addOrUpdateCheck adds a new check or updates an existing one in the agent's checks.
func addOrUpdateCheck(agent AgentConfig, serviceType, serviceName, details string, port int32) (AgentConfig, bool) {
	actualType, actualName := determineCheckTypeAndName(serviceType, serviceName)
	newCheck := createCheck(actualType, actualName, details, port)

	// Check if a matching check exists
	for i, check := range agent.Checks {
		if isMatchingCheck(check, actualType, actualName, serviceType) {
			agent.Checks[i] = newCheck

			return agent, true
		}
	}

	// No match found, append new check
	agent.Checks = append(agent.Checks, newCheck)

	return agent, false
}

const (
	serviceTypeGRPC = "grpc"
)

// determineCheckTypeAndName adjusts the service type and name for GRPC services.
func determineCheckTypeAndName(serviceType, serviceName string) (actualType, actualName string) {
	if isGRPCService(serviceType) {
		if serviceName == serviceType {
			actualType, actualName = serviceTypeGRPC, serviceType
		} else {
			actualType, actualName = serviceTypeGRPC, serviceName
		}
	} else {
		actualType, actualName = serviceType, serviceName
	}

	return actualType, actualName
}

// createCheck constructs a new CheckConfig with the provided details.
func createCheck(serviceType, serviceName, details string, port int32) CheckConfig {
	check := CheckConfig{
		ServiceType: serviceType,
		ServiceName: serviceName,
		Details:     details,
	}

	if port > 0 {
		check.Port = port
	}

	return check
}

// isMatchingCheck determines if a check matches the criteria for replacement.
func isMatchingCheck(check CheckConfig, actualType, actualName, serviceType string) bool {
	// Direct match
	if check.ServiceType == actualType && check.ServiceName == actualName {
		return true
	}

	// Match for GRPC service with service name matching the provided service type
	if actualType == serviceTypeGRPC && check.ServiceType == serviceTypeGRPC && check.ServiceName == serviceType {
		return true
	}

	return false
}

// removeChecker removes a service check from the specified agent in the poller configuration.
func removeChecker(pollerFile, agentName, serviceType, serviceName string) error {
	config, err := readPollerConfig(pollerFile)
	if err != nil {
		return err
	}

	agent, exists := config.Agents[agentName]
	if !exists {
		return fmt.Errorf("%w: %s", errAgentNotFound, agentName)
	}

	updatedAgent, found := removeCheck(agent, serviceType, serviceName)
	if !found {
		listAvailableCheckers(agent.Checks, agentName, serviceType)

		return fmt.Errorf("%w %s: %s", errCheckerNotFound, serviceType, agentName)
	}

	config.Agents[agentName] = updatedAgent

	return writePollerConfig(pollerFile, config)
}

// removeCheck removes a check from the agent's checks based on service type and name.
func removeCheck(agent AgentConfig, serviceType, serviceName string) (AgentConfig, bool) {
	newChecks := make([]CheckConfig, 0, len(agent.Checks))
	found := false

	for _, check := range agent.Checks {
		if shouldRemoveCheck(check, serviceType, serviceName) {
			fmt.Printf("Removing checker: %s/%s\n", check.ServiceType, check.ServiceName)

			found = true

			continue
		}

		newChecks = append(newChecks, check)
	}

	agent.Checks = newChecks

	return agent, found
}

// shouldRemoveCheck determines if a check should be removed based on matching criteria.
func shouldRemoveCheck(check CheckConfig, serviceType, serviceName string) bool {
	// Direct match by type and name
	if check.ServiceType == serviceType && check.ServiceName == serviceName {
		return true
	}

	// GRPC service name matches the target type
	if check.ServiceType == serviceTypeGRPC && check.ServiceName == serviceType {
		return true
	}

	// Service type and name are the same and match the check's name
	if serviceType == serviceName && check.ServiceName == serviceType {
		return true
	}

	return false
}

// listAvailableCheckers prints all available checkers for the agent.
func listAvailableCheckers(checks []CheckConfig, _, _ string) {
	fmt.Println("Available checkers in configuration:")

	for _, check := range checks {
		fmt.Printf("  - %s/%s\n", check.ServiceType, check.ServiceName)
	}
}

// enableAllCheckers enables all standard checkers for a given agent in the poller config.
func enableAllCheckers(pollerFile, agentName string) error {
	config, err := readPollerConfig(pollerFile)
	if err != nil {
		return err
	}

	agent, exists := config.Agents[agentName]
	if !exists {
		return fmt.Errorf("%w: %s", errAgentNotFound, agentName)
	}

	ip := extractIP(agent.Address)
	updatedAgent, addedCount := addStandardCheckers(agent, ip)

	if addedCount == 0 {
		fmt.Println("All standard checkers are already enabled.")

		return nil
	}

	config.Agents[agentName] = updatedAgent

	return writePollerConfig(pollerFile, config)
}

// readPollerConfig reads and parses the poller configuration file.
func readPollerConfig(pollerFile string) (*PollerConfig, error) {
	data, err := os.ReadFile(pollerFile)
	if err != nil {
		return &PollerConfig{}, fmt.Errorf("failed to read poller config file: %w", err)
	}

	var config PollerConfig

	if err := json.Unmarshal(data, &config); err != nil {
		return &PollerConfig{}, fmt.Errorf("failed to parse poller config: %w", err)
	}

	return &config, nil
}

const (
	defaultIPAddress = "127.0.0.1"
)

// extractIP extracts the IP address from the agent's address, defaulting to "127.0.0.1".
func extractIP(address string) string {
	if address == "" {
		return defaultIPAddress
	}

	parts := strings.Split(address, ":")

	if len(parts) > 0 && parts[0] != "" {
		return parts[0]
	}

	return defaultIPAddress
}

// addStandardCheckers adds standard checkers to the agent if they don't already exist.
func addStandardCheckers(agent AgentConfig, ip string) (updatedAgent AgentConfig, addedCount int) {
	updatedAgent = agent
	standardCheckers := []CheckConfig{
		{ServiceType: "process", ServiceName: "serviceradar-agent", Details: "serviceradar-agent"},
		{ServiceType: "port", ServiceName: "SSH", Details: "127.0.0.1:22"},
		{ServiceType: "icmp", ServiceName: "ping", Details: "1.1.1.1"},
		{ServiceType: "sweep", ServiceName: "network_sweep", Details: ""},
		{ServiceType: serviceTypeGRPC, ServiceName: "snmp", Details: ip + getDefaultPorts()[typeSNMP]},
		{ServiceType: serviceTypeGRPC, ServiceName: "rperf-checker", Details: ip + getDefaultPorts()[typeRPerf]},
		{ServiceType: serviceTypeGRPC, ServiceName: "sysmon", Details: ip + getDefaultPorts()[typeSysMon]},
		{ServiceType: serviceTypeGRPC, ServiceName: "dusk", Details: ip + getDefaultPorts()[typeDusk]},
	}

	existingChecks := buildExistingChecksMap(updatedAgent.Checks)
	addedCount = 0

	for _, check := range standardCheckers {
		key := generateCheckKey(check)

		if !existingChecks[key] {
			updatedAgent.Checks = append(updatedAgent.Checks, check)
			fmt.Printf("Added checker: %s/%s\n", check.ServiceType, check.ServiceName)

			addedCount++
		}
	}

	return updatedAgent, addedCount
}

// buildExistingChecksMap creates a map of existing checks for quick lookup.
func buildExistingChecksMap(checks []CheckConfig) map[string]bool {
	existingChecks := make(map[string]bool)

	for _, check := range checks {
		key := generateCheckKey(check)

		existingChecks[key] = true
	}

	return existingChecks
}

// generateCheckKey generates a unique key for a check based on its type and name.
func generateCheckKey(check CheckConfig) string {
	if check.ServiceType == serviceTypeGRPC {
		return check.ServiceName
	}

	return check.ServiceType + "/" + check.ServiceName
}
