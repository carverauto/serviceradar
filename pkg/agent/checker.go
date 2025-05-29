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

// Package agent pkg/agent/checker.go
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

const (
	partsForPortDetails  = 2
	maxProcessNameLength = 256
)

var (
	// validServiceName ensures service names only contain alphanumeric chars, hyphens, and underscores.
	validServiceName = regexp.MustCompile(`^[a-zA-Z0-9\-_.]+$`)

	// Common errors.
	errInvalidProcessName = errors.New("invalid process name")
	errInvalidCharacters  = errors.New("contains invalid characters (only alphanumeric, " +
		"hyphens, underscores, and periods are allowed)")
)

type ProcessChecker struct {
	ProcessName string
}

func (p *ProcessChecker) validateProcessName() error {
	if len(p.ProcessName) > maxProcessNameLength {
		return fmt.Errorf("%w: process name too long (max %d characters)",
			errInvalidProcessName, maxProcessNameLength)
	}

	if !validServiceName.MatchString(p.ProcessName) {
		return fmt.Errorf("%w: %s", errInvalidCharacters, p.ProcessName)
	}

	return nil
}

// Check validates if a process is running.
func (p *ProcessChecker) Check(ctx context.Context, req *proto.StatusRequest) (isActive bool, statusMsg json.RawMessage) {
	log.Printf("Checking process %q", p.ProcessName)

	if err := p.validateProcessName(); err != nil {
		log.Printf("Failed to validate process name: %v", err)
		return false, jsonError(fmt.Sprintf("Invalid process name: %v", err))
	}

	// Use the validated process name which is guaranteed to be safe
	// as it only contains alphanumeric chars, hyphens, underscores, and periods
	validatedProcessName := p.ProcessName
	cmd := exec.CommandContext(ctx, "systemctl", "is-active", validatedProcessName)
	log.Printf("Running command: %v", cmd)

	output, err := cmd.Output()
	if err != nil {
		return false, jsonError(fmt.Sprintf("Process %s is not running: %v", p.ProcessName, err))
	}

	log.Printf("Process %s is running", p.ProcessName)

	isActive = true
	status := strings.TrimSpace(string(output))

	resp := map[string]interface{}{
		"status":       status,
		"process_name": p.ProcessName,
		"active":       isActive,
		"agent_id":     req.AgentId,
		"poller_id":    req.PollerId,
	}

	data, err := json.Marshal(resp)
	if err != nil {
		return false, jsonError(fmt.Sprintf("Failed to marshal response: %v", err))
	}

	return isActive, data
}

type PortChecker struct {
	Host string
	Port int
}

func NewPortChecker(details string) (*PortChecker, error) {
	log.Printf("Creating new port checker with details: %s", details)

	if details == "" {
		log.Printf("NewPortChecker: %v", errDetailsRequiredPorts)
		return nil, errDetailsRequiredPorts
	}

	// Split the details into host and port
	parts := strings.Split(details, ":")
	if len(parts) != partsForPortDetails {
		return nil, errInvalidDetailsFormat
	}

	host := parts[0]

	port, err := strconv.Atoi(parts[1])
	if err != nil {
		return nil, fmt.Errorf("%w: %d", errInvalidPort, port)
	}

	if port <= 0 || port > 65535 {
		return nil, fmt.Errorf("%w: %d", errInvalidPort, port)
	}

	log.Printf("Successfully created port checker for %s:%d", host, port)

	return &PortChecker{
		Host: host,
		Port: port,
	}, nil
}

// Check validates if a port is accessible.
func (p *PortChecker) Check(ctx context.Context, _ *proto.StatusRequest) (isAccessible bool, statusMsg json.RawMessage) {
	var d net.Dialer

	addr := fmt.Sprintf("%s:%d", p.Host, p.Port)

	start := time.Now()

	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return false, jsonError(fmt.Sprintf("Port %d is not accessible: %v", p.Port, err))
	}

	responseTime := time.Since(start).Nanoseconds()

	if err = conn.Close(); err != nil {
		log.Printf("Error closing connection: %v", err)
		return false, jsonError("Error closing connection")
	}

	resp := map[string]interface{}{
		"host":          p.Host,
		"port":          p.Port,
		"response_time": responseTime,
	}

	data, err := json.Marshal(resp)
	if err != nil {
		return false, jsonError(fmt.Sprintf("Failed to marshal response: %v", err))
	}

	return true, data
}

func (*PortChecker) Close() error {
	return nil // No resources to close
}

// Helper function to create error JSON
func jsonError(msg string) json.RawMessage {
	data, _ := json.Marshal(map[string]string{"error": msg})
	return data
}

func (*ProcessChecker) Close() error {
	return nil // No resources to close
}
