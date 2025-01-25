// Package agent pkg/agent/checker.go
package agent

import (
	"context"
	"fmt"
	"log"
	"net"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	// validServiceName ensures service names only contain alphanumeric chars, hyphens, and underscores.
	validServiceName = regexp.MustCompile(`^[a-zA-Z0-9-_]+$`)

	// Common errors.
	errInvalidProcessName = fmt.Errorf("invalid process name")
)

type ProcessChecker struct {
	ProcessName string
}

func (p *ProcessChecker) validateProcessName() error {
	if !validServiceName.MatchString(p.ProcessName) {
		return fmt.Errorf("%w: %s", errInvalidProcessName, p.ProcessName)
	}

	return nil
}

// Check validates if a process is running.
func (p *ProcessChecker) Check(ctx context.Context) (isActive bool, statusMsg string) {
	// Validate process name before executing command
	if err := p.validateProcessName(); err != nil {
		return false, fmt.Sprintf("Invalid process name: %v", err)
	}

	cmd := exec.CommandContext(ctx, "systemctl", "is-active", p.ProcessName) //nolint:gosec // checking above

	output, err := cmd.Output()
	if err != nil {
		return false, fmt.Sprintf("Process %s is not running", p.ProcessName)
	}

	status := strings.TrimSpace(string(output))

	return status == "active", fmt.Sprintf("Process status: %s", status)
}

type PortChecker struct {
	Host string
	Port int
}

func NewPortChecker(details string) (*PortChecker, error) {
	if details == "" {
		return nil, fmt.Errorf("details field is required for port checks")
	}

	// Split the details into host and port
	parts := strings.Split(details, ":")
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid details format: expected 'host:port'")
	}

	host := parts[0]
	port, err := strconv.Atoi(parts[1])
	if err != nil {
		return nil, fmt.Errorf("invalid port: %w", err)
	}

	if port <= 0 || port > 65535 {
		return nil, fmt.Errorf("invalid port: %d", port)
	}

	return &PortChecker{
		Host: host,
		Port: port,
	}, nil
}

func (p *PortChecker) Check(ctx context.Context) (isAccessible bool, statusMsg string) {
	var d net.Dialer

	addr := fmt.Sprintf("%s:%d", p.Host, p.Port)

	start := time.Now()
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return false, fmt.Sprintf(`{"error": "Port %d is not accessible: %v"}`, p.Port, err)
	}

	responseTime := time.Since(start).Nanoseconds()
	if err = conn.Close(); err != nil {
		log.Printf("Error closing connection: %v", err)
		return false, `{"error": "Error closing connection"}`
	}

	return true, fmt.Sprintf(`{"host": "%s", "port": %d, "response_time": %d}`, p.Host, p.Port, responseTime) // Return raw data
}
