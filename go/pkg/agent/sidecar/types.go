/*
 * Copyright 2026 Carver Automation Corporation.
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

package sidecar

import (
	"context"
	"time"
)

// Client is the minimal health-probe client contract used by the manager.
type Client interface {
	Ping(context.Context) error
	Close() error
}

// ClientFactory opens a health client for a sidecar socket.
type ClientFactory func(ctx context.Context, socketPath string) (Client, error)

// Sidecar describes a long-lived agent child process.
type Sidecar interface {
	Name() string
	BinaryPath() string
	Args(socketPath, configPath string) []string
	OnHealthy(Client)
	OnUnhealthy(error)
}

// State is the lifecycle state reported for a sidecar process.
type State string

const (
	StateStopped     State = "stopped"
	StateStarting    State = "starting"
	StateRunning     State = "running"
	StateHealthy     State = "healthy"
	StateUnhealthy   State = "unhealthy"
	StateRestarting  State = "restarting"
	StateFailed      State = "failed"
	StateCircuitOpen State = "circuit_open"
)

// Status is a snapshot of one managed sidecar.
type Status struct {
	Name          string    `json:"name"`
	State         State     `json:"state"`
	PID           int       `json:"pid,omitempty"`
	LastHealthAt  time.Time `json:"last_health_at,omitempty"`
	RestartCount  int       `json:"restart_count"`
	LastError     string    `json:"last_error,omitempty"`
	SocketPath    string    `json:"socket_path,omitempty"`
	ConfigPath    string    `json:"config_path,omitempty"`
	LastStartedAt time.Time `json:"last_started_at,omitempty"`
	LastExitedAt  time.Time `json:"last_exited_at,omitempty"`
}
