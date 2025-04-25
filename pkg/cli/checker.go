package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// isGRPCService determines if a service type is actually implemented as a gRPC service
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
	// Read and parse poller.json
	data, err := os.ReadFile(pollerFile)
	if err != nil {
		return fmt.Errorf("failed to read poller config file: %w", err)
	}

	var config PollerConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("failed to parse poller config: %w", err)
	}

	// Find the agent
	agent, exists := config.Agents[agentName]
	if !exists {
		return fmt.Errorf("%w: %s", errAgentNotFound, agentName)
	}

	// Determine if this should be a grpc service
	actualType := serviceType
	actualName := serviceName

	// Handle special built-in checkers that are implemented as GRPC services
	if isGRPCService(serviceType) {
		actualType = "grpc"
		// If the service name is the same as type, use the type as name
		if serviceName == serviceType {
			actualName = serviceType
		}
	}

	// Create the new check
	newCheck := CheckConfig{
		ServiceType: actualType,
		ServiceName: actualName,
		Details:     details,
	}

	if port > 0 {
		newCheck.Port = port
	}

	// Check if a checker with the same functionality already exists
	exists = false
	for i, check := range agent.Checks {
		// Direct match
		if check.ServiceType == actualType && check.ServiceName == actualName {
			// Update existing check
			agent.Checks[i] = newCheck
			config.Agents[agentName] = agent
			exists = true
			break
		}

		// Match for grpc service with service name matching our service type
		if actualType == "grpc" && check.ServiceType == "grpc" && check.ServiceName == serviceType {
			// Update existing check
			agent.Checks[i] = newCheck
			config.Agents[agentName] = agent
			exists = true
			break
		}
	}

	// If the check doesn't exist, add it
	if !exists {
		agent.Checks = append(agent.Checks, newCheck)
		config.Agents[agentName] = agent
		fmt.Printf("Added checker: %s/%s\n", actualType, actualName)
	} else {
		fmt.Printf("Updated existing checker: %s/%s\n", actualType, actualName)
	}

	// Write updated config
	return writePollerConfig(pollerFile, config)
}

// removeChecker removes a service check from the specified agent in the poller configuration.
func removeChecker(pollerFile, agentName, serviceType, serviceName string) error {
	// Read and parse poller.json
	data, err := os.ReadFile(pollerFile)
	if err != nil {
		return fmt.Errorf("failed to read poller config file: %w", err)
	}

	var config PollerConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("failed to parse poller config: %w", err)
	}

	// Find the agent
	agent, exists := config.Agents[agentName]
	if !exists {
		return fmt.Errorf("%w: %s", errAgentNotFound, agentName)
	}

	// Find and remove the check
	found := false
	newChecks := make([]CheckConfig, 0, len(agent.Checks))
	for _, check := range agent.Checks {
		// Handle special case for GRPC services
		shouldRemove := false

		// Direct match by type and name
		if check.ServiceType == serviceType && check.ServiceName == serviceName {
			shouldRemove = true
		}

		// Handle case where service type is "grpc" and service name matches our target type
		if check.ServiceType == "grpc" && check.ServiceName == serviceType {
			shouldRemove = true
		}

		// If service type is the same as the name we provided, also check by name
		if serviceType == serviceName && check.ServiceName == serviceType {
			shouldRemove = true
		}

		if shouldRemove {
			found = true
			fmt.Printf("Removing checker: %s/%s\n", check.ServiceType, check.ServiceName)
			continue
		}

		newChecks = append(newChecks, check)
	}

	if !found {
		// List all available checkers to help the user
		fmt.Println("Available checkers in configuration:")
		for _, check := range agent.Checks {
			fmt.Printf("  - %s/%s\n", check.ServiceType, check.ServiceName)
		}
		return fmt.Errorf("checker '%s' not found for agent %s", serviceType, agentName)
	}

	agent.Checks = newChecks
	config.Agents[agentName] = agent

	// Write updated config
	return writePollerConfig(pollerFile, config)
}

// enableAllCheckers adds all standard checkers to the specified agent.
func enableAllCheckers(pollerFile, agentName string) error {
	// Read and parse poller.json
	data, err := os.ReadFile(pollerFile)
	if err != nil {
		return fmt.Errorf("failed to read poller config file: %w", err)
	}

	var config PollerConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("failed to parse poller config: %w", err)
	}

	// Find the agent
	agent, exists := config.Agents[agentName]
	if !exists {
		return fmt.Errorf("%w: %s", errAgentNotFound, agentName)
	}

	// Extract IP address from the agent config if possible
	ip := "127.0.0.1" // default
	if agent.Address != "" {
		parts := strings.Split(agent.Address, ":")
		if len(parts) > 0 && parts[0] != "" {
			ip = parts[0]
		}
	}

	// Define standard checkers
	standardCheckers := []CheckConfig{
		{
			ServiceType: "process",
			ServiceName: "serviceradar-agent",
			Details:     "serviceradar-agent",
		},
		{
			ServiceType: "port",
			ServiceName: "SSH",
			Details:     "127.0.0.1:22",
		},
		{
			ServiceType: "icmp",
			ServiceName: "ping",
			Details:     "1.1.1.1",
		},
		{
			ServiceType: "sweep",
			ServiceName: "network_sweep",
			Details:     "",
		},
		{
			ServiceType: "grpc",
			ServiceName: "snmp",
			Details:     ip + defaultPorts[typeSNMP],
		},
		{
			ServiceType: "grpc",
			ServiceName: "rperf-checker",
			Details:     ip + defaultPorts[typeRPerf],
		},
		{
			ServiceType: "grpc",
			ServiceName: "sysmon",
			Details:     ip + defaultPorts[typeSysMon],
		},
		{
			ServiceType: "grpc",
			ServiceName: "dusk",
			Details:     ip + defaultPorts[typeDusk],
		},
	}

	// Create a map of existing checks for quick lookup
	existingChecks := make(map[string]bool)
	for _, check := range agent.Checks {
		// Use service name as key for GRPC services
		key := check.ServiceName
		if check.ServiceType != "grpc" {
			key = check.ServiceType + "/" + check.ServiceName
		}
		existingChecks[key] = true
	}

	// Add new checkers if they don't already exist
	addedCount := 0
	for _, check := range standardCheckers {
		// Use service name as key for GRPC services
		key := check.ServiceName
		if check.ServiceType != "grpc" {
			key = check.ServiceType + "/" + check.ServiceName
		}

		if !existingChecks[key] {
			agent.Checks = append(agent.Checks, check)
			fmt.Printf("Added checker: %s/%s\n", check.ServiceType, check.ServiceName)
			addedCount++
		}
	}

	if addedCount == 0 {
		fmt.Println("All standard checkers are already enabled.")
		return nil
	}

	config.Agents[agentName] = agent

	// Write updated config
	return writePollerConfig(pollerFile, config)
}
