// Package agent pkg/agent/checker.go
package agent

import (
	"context"
	"fmt"
	"log"
	"net"
	"os/exec"
	"regexp"
	"strings"
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

func (p *PortChecker) Check(ctx context.Context) (isAccessible bool, statusMsg string) {
	var d net.Dialer

	addr := fmt.Sprintf("%s:%d", p.Host, p.Port)

	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return false, fmt.Sprintf("Port %d is not accessible: %v", p.Port, err)
	}

	if err = conn.Close(); err != nil {
		log.Printf("Error closing connection: %v", err)

		return false, "Error closing connection"
	}

	return true, fmt.Sprintf("Port %d is accessible", p.Port)
}
