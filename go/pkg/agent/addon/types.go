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

// Package addon supervises native agent add-ons that run as out-of-process
// HashiCorp go-plugin subprocesses speaking gRPC over a restricted Unix-domain
// socket with AutoMTLS. It is the agent-side (go-plugin client) counterpart to the
// author SDK in go/pkg/addon/sdk and the canonical "agent-sidecar" supervision
// runtime for issue 3425. The manager owns per-add-on lifecycle (launch, configure,
// health, restart with backoff, circuit breaker, graceful stop) and reconciles a
// desired set of add-ons via Apply, mirroring the supervision semantics of
// go/pkg/agent/sidecar but built fresh on go-plugin rather than the bespoke
// framed-protobuf UDS protocol.
package addon

import (
	"context"
	"errors"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

var (
	// ErrManagerClosed is returned when Apply is called after Stop.
	ErrManagerClosed = errors.New("addon manager closed")
	// ErrAddonExited indicates the add-on subprocess exited unexpectedly.
	ErrAddonExited = errors.New("addon exited")
	// ErrUnexpectedClientType indicates the dispensed go-plugin client was not the
	// expected add-on type.
	ErrUnexpectedClientType = errors.New("unexpected add-on gRPC client type")
	// ErrConfigurationRejected indicates the add-on rejected its configuration.
	ErrConfigurationRejected = errors.New("addon rejected configuration")
	// ErrCredentialResolverUnavailable indicates the assignment requested
	// gateway-brokered credentials, but the agent has no resolver installed.
	ErrCredentialResolverUnavailable = errors.New("addon credential resolver unavailable")
	// ErrInvalidConfig indicates the delivered add-on config cannot be safely
	// extended with ServiceRadar runtime metadata.
	ErrInvalidConfig = errors.New("invalid addon config")
	// ErrAddonCommandUnavailable indicates the add-on is not running or does not
	// expose the native command RPC.
	ErrAddonCommandUnavailable = errors.New("addon command unavailable")
	// ErrAddonAssignmentNotFound indicates no running add-on assignment matched a
	// command invocation.
	ErrAddonAssignmentNotFound = errors.New("addon assignment not found")
)

// State is the lifecycle state reported for a supervised add-on.
type State string

const (
	StateStopped  State = "stopped"
	StateStarting State = "starting"
	StateRunning  State = "running"
	// StateDegraded is running, but the add-on reported something worth an
	// operator's attention -- most often an unsatisfied external dependency or a
	// host policy it cannot enforce. It is deliberately distinct from
	// StateUnhealthy: the add-on process is up and doing its job, so a rollout
	// must not treat it as a failed candidate. The reason is still reported and
	// still surfaces on the fleet row.
	StateDegraded    State = "degraded"
	StateUnhealthy   State = "unhealthy"
	StateRestarting  State = "restarting"
	StateCircuitOpen State = "circuit_open"
)

// Spec is a desired add-on assignment the manager should supervise.
type Spec struct {
	// AssignmentID is the control-plane assignment identifier used to scope
	// gateway-staged artifacts. When empty, ID is used as the assignment scope.
	AssignmentID string
	// ID is the stable add-on identifier (matches addon.yaml id).
	ID string
	// Version is the assigned add-on version (informational).
	Version string
	// BinaryPath is the absolute path to the add-on plugin binary.
	BinaryPath string
	// Args are optional extra arguments passed to the plugin binary.
	Args []string
	// ConfigJSON is the operator-selected configuration delivered to the add-on
	// via Configure (already validated by the control plane).
	ConfigJSON []byte
	// Capabilities are the capability identifiers the add-on advertises.
	Capabilities []string
	// DownloadURL is the gateway artifact URL from the delivered assignment. It
	// anchors the agent-gateway origin used for durable artifact upload.
	DownloadURL string
	// Resources are the manifest-declared CPU/memory/task limits enforced on the
	// add-on subprocess (manifest `resources`). Zero means unbounded.
	Resources Resources
}

// Resources are the CPU/memory/task limits the supervisor enforces on an add-on
// subprocess so edge compute cannot impact the host or the base agent. Mirrors
// the manifest `resources` block (cpu_max_percent / memory_max_bytes /
// memory_high_bytes / tasks_max / slice).
type Resources struct {
	CPUMaxPercent   float64 `json:"cpu_max_percent,omitempty"`
	MemoryMaxBytes  int64   `json:"memory_max_bytes,omitempty"`
	MemoryHighBytes int64   `json:"memory_high_bytes,omitempty"`
	TasksMax        int     `json:"tasks_max,omitempty"`
	Slice           string  `json:"slice,omitempty"`
}

// IsZero reports whether no limits are declared.
func (r Resources) IsZero() bool {
	return r.CPUMaxPercent == 0 && r.MemoryMaxBytes == 0 && r.MemoryHighBytes == 0 &&
		r.TasksMax == 0 && r.Slice == ""
}

// Status is a snapshot of one supervised add-on.
type Status struct {
	ID                string    `json:"id"`
	State             State     `json:"state"`
	Version           string    `json:"version,omitempty"`
	Arch              string    `json:"arch,omitempty"`
	Capabilities      []string  `json:"capabilities,omitempty"`
	DegradationReason string    `json:"degradation_reason,omitempty"`
	ConfigHash        string    `json:"config_hash,omitempty"`
	ResourceCgroup    string    `json:"resource_cgroup,omitempty"`
	ResourceLimitErr  string    `json:"resource_limit_error,omitempty"`
	PID               int       `json:"pid,omitempty"`
	RestartCount      int       `json:"restart_count"`
	LastError         string    `json:"last_error,omitempty"`
	LastHealthAt      time.Time `json:"last_health_at,omitempty"`
	LastStartedAt     time.Time `json:"last_started_at,omitempty"`
	LastExitedAt      time.Time `json:"last_exited_at,omitempty"`
}

// CommandInvocation identifies one native add-on action invocation delivered
// through the agent control stream.
type CommandInvocation struct {
	AssignmentID string
	AddonID      string
	CommandID    string
	CommandType  string
	ActionID     string
	Schema       string
	PayloadJSON  []byte
	Timeout      time.Duration
	DeadlineUnix int64
	Metadata     map[string]string
}

// AddonManager is the agent-facing contract for supervising native add-ons.
type AddonManager interface {
	// Apply reconciles the supervised add-ons to the desired set: it launches new
	// add-ons, stops removed ones, and reconfigures changed ones.
	Apply(ctx context.Context, specs []Spec) error
	// SetCredentialResolver installs the gateway-backed credential resolver used
	// for native add-on configure-time credential injection.
	SetCredentialResolver(resolver coreaddon.CredentialResolver)
	// Status returns a stable snapshot of every supervised add-on.
	Status() []Status
	// RunCommand executes a generic command against a supervised add-on.
	RunCommand(ctx context.Context, invocation CommandInvocation) (coreaddon.CommandResult, error)
	// PublishMetricFeed offers one encoded serviceradar.metric.v1.MetricBatch to
	// running metric-feed:v1 add-ons that explicitly subscribe to source. The
	// call must be non-blocking for the agent collection/push path; it returns the
	// number of add-on queues that accepted the frame.
	PublishMetricFeed(source string, payload []byte) int
	// Stop terminates all add-ons and waits for their supervisors to exit.
	Stop(ctx context.Context) error
}
