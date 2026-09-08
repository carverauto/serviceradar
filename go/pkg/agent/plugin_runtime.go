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

package agent

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/tetratelabs/wazero"
)

const (
	pluginHostModule                 = "env"
	pluginDefaultInterval            = 60 * time.Second
	pluginDefaultTimeout             = 10 * time.Second
	pluginMaxPayloadBytes            = 2 * 1024 * 1024
	pluginMaxActionIngestResultBytes = 12 * 1024 * 1024
	pluginMaxWasmBytes               = 64 * 1024 * 1024
	pluginMaxHTTPBodyBytes           = 2 * 1024 * 1024
	pluginDefaultHTTPTimeout         = 15 * time.Second
	pluginWarmupGrace                = 2 * time.Minute
)

const (
	pluginCapabilityCameraMediaStream  = "camera_media_stream"
	pluginCapabilityProxmoxConsole     = "proxmox_console_stream"
	pluginCapabilityEmitTelemetry      = "emit_telemetry"
	pluginCapabilityArtifactStaging    = "artifact-staging:v1"
	pluginCapabilityActionResultIngest = "action-result-ingest:v1"
	pluginCapabilityActionOnly         = "action-only:v1"
	pluginCapabilityNotify             = "notify:v1"
)

const (
	pluginErrOK        int32 = 0
	pluginErrInvalid   int32 = -1
	pluginErrDenied    int32 = -2
	pluginErrTooLarge  int32 = -3
	pluginErrNotFound  int32 = -4
	pluginErrInternal  int32 = -5
	pluginErrTimeout   int32 = -6
	pluginErrBadHandle int32 = -7
)

var (
	errPluginWasmUnavailable                = errors.New("plugin wasm unavailable")
	errEntrypointNotFound                   = errors.New("entrypoint not found")
	errDownloadFailed                       = errors.New("download failed")
	errDownloadTooLarge                     = errors.New("download too large")
	errContentHashMismatch                  = errors.New("content hash mismatch")
	errInvalidPath                          = errors.New("invalid path")
	errPluginAssignmentNotFound             = errors.New("plugin assignment not found")
	errPluginAdmissionDenied                = errors.New("admission denied: max concurrent reached")
	errPluginActionAlreadyRunning           = errors.New("plugin action already running for assignment")
	errPluginActionResultMissing            = errors.New("no result submitted")
	errStreamingPluginAssignmentNotFound    = errors.New("streaming plugin assignment not found")
	errStreamingPluginAdmissionDenied       = errors.New("streaming plugin admission denied: max concurrent reached")
	errStreamingPluginMediaSessionMissing   = errors.New("streaming plugin did not open a camera media session")
	errStreamingPluginConsoleNotOpened      = errors.New("streaming plugin did not open a Proxmox console session")
	errCredentialBrokerResolverUnavailable  = errors.New("credential broker resolver unavailable")
	errCredentialBrokerMaterialUnavailable  = errors.New("credential broker material unavailable")
	errCredentialBrokerInjectionUnsupported = errors.New("credential broker injection unsupported")
	errCredentialBrokerInsecureTLSDenied    = errors.New("credential broker injection denied for insecure TLS request")
	errCredentialBrokerSecretFieldPresent   = errors.New("credential broker secret field must not be caller supplied")
	errCredentialBrokerFormInvalid          = errors.New("credential broker form injection request is invalid")
	errCredentialBrokerTokenExchangeInvalid = errors.New("credential broker token exchange policy is invalid")
	errCredentialBrokerTokenExchangeFailed  = errors.New("credential broker token exchange failed")
	errPluginActionResultInvalid            = errors.New("plugin action result is invalid")
	errPluginActionResultBackpressure       = errors.New("plugin action result queue unavailable")
)

// PluginManagerConfig configures the Wasm plugin manager.
type PluginManagerConfig struct {
	CacheDir                      string
	LocalStoreDir                 string
	Logger                        logger.Logger
	HTTPClient                    *http.Client
	ArtifactHTTPClient            *http.Client
	CredentialBroker              CredentialBrokerResolver
	AWXCallbackCredentialResolver AWXCallbackCredentialEnvelopeResolver
	ArtifactUploader              PluginArtifactUploader
}

// CredentialBrokerResolver resolves a validated broker grant for agent-owned
// operations. It must not return material to the Wasm module.
type CredentialBrokerResolver interface {
	ResolveCredentialGrant(context.Context, credentialBrokerGrant) (CredentialBrokerMaterial, error)
}

// CredentialBrokerMaterial is memory-only credential material returned to the
// agent host function after policy validation.
type CredentialBrokerMaterial = coreaddon.CredentialBrokerMaterial

// PluginManager manages Wasm plugin assignments and execution.
type PluginManager struct {
	logger                        logger.Logger
	cacheDir                      string
	localStoreDir                 string
	httpClient                    *http.Client
	artifactHTTPClient            *http.Client
	compilationCache              wazero.CompilationCache
	credentialBroker              CredentialBrokerResolver
	awxCallbackCredentialResolver AWXCallbackCredentialEnvelopeResolver
	artifactUploader              PluginArtifactUploader
	credentialCache               map[string]credentialBrokerCacheEntry
	credentialNow                 func() time.Time
	credentialMu                  sync.Mutex
	awxCallbackCredentialMu       sync.Mutex
	artifactMu                    sync.Mutex

	ctx    context.Context
	cancel context.CancelFunc

	mu      sync.RWMutex
	runners map[string]*pluginRunner
	streams map[string]*pluginAssignment
	actions map[string]*pluginAssignment
	results chan PluginResult
	signals chan PluginSignalTelemetry

	actionMu              sync.Mutex
	activeActions         map[string]struct{}
	streamExecutionMu     sync.Mutex
	streamExecutions      map[uint64]activePluginStreamExecution
	nextStreamExecutionID uint64

	// conditions de-duplicates per-cycle plugin condition events (e.g. Proxmox
	// resource pressure/bottleneck) so only level transitions are forwarded.
	conditions *pluginConditionDebouncer

	stateMu  sync.Mutex
	states   map[string]*assignmentState
	stateNow func() time.Time

	limitsMu         sync.Mutex
	limits           pluginEngineLimits
	concurrentActive int
	openConnections  int

	statsMu sync.Mutex
	stats   pluginEngineStats

	configMu        sync.Mutex
	lastConfigSHA   string
	cacheCloseOnce  sync.Once
	streamExecutor  func(context.Context, *pluginAssignment, []byte, []byte, *pluginCameraMediaBridge) error
	consoleExecutor func(context.Context, *pluginAssignment, []byte, []byte, *pluginProxmoxConsoleBridge) error
}

type assignmentState struct {
	firstSeen   time.Time
	ready       bool
	contentHash string
}

type credentialBrokerCacheEntry struct {
	material  CredentialBrokerMaterial
	expiresAt time.Time
}

type activePluginStreamExecution struct {
	assignmentID string
	generation   string
	cancel       context.CancelFunc
}

// PluginResult captures a raw plugin result payload.
type PluginResult struct {
	AssignmentID string
	PluginID     string
	PluginName   string
	Payload      []byte
	ObservedAt   time.Time
}

type pluginEngineStats struct {
	assignmentsTotal     int
	assignmentsAdmitted  int
	assignmentsRejected  int
	requestedMemoryMB    int
	requestedCPUMS       int
	requestedConnections int
	lastConfigAt         time.Time
	execTotal            int64
	execFailures         int64
	lastExecAt           time.Time
	lastFailureAt        time.Time
}

type PluginEngineSnapshot struct {
	ObservedAt           time.Time
	Limits               pluginEngineLimits
	RequestedMemoryMB    int
	RequestedCPUMS       int
	RequestedConnections int
	AssignmentsTotal     int
	AssignmentsAdmitted  int
	AssignmentsRejected  int
	ActiveExecutions     int
	OpenConnections      int
	ExecTotal            int64
	ExecFailures         int64
	LastExecAt           time.Time
	LastFailureAt        time.Time
	LastConfigAt         time.Time
}

type PluginEngineDebugSnapshot struct {
	Engine      PluginEngineSnapshot             `json:"engine"`
	Assignments []PluginEngineAssignmentSnapshot `json:"assignments"`
}

type PluginEngineAssignmentSnapshot struct {
	AssignmentID         string   `json:"assignment_id"`
	PluginID             string   `json:"plugin_id"`
	PackageID            string   `json:"package_id,omitempty"`
	Version              string   `json:"version,omitempty"`
	Name                 string   `json:"name,omitempty"`
	Entrypoint           string   `json:"entrypoint,omitempty"`
	Runtime              string   `json:"runtime,omitempty"`
	Mode                 string   `json:"mode"`
	Outputs              string   `json:"outputs,omitempty"`
	Capabilities         []string `json:"capabilities,omitempty"`
	IntervalSeconds      int64    `json:"interval_seconds,omitempty"`
	TimeoutSeconds       int64    `json:"timeout_seconds,omitempty"`
	WasmObject           string   `json:"wasm_object,omitempty"`
	ContentHash          string   `json:"content_hash,omitempty"`
	DownloadHost         string   `json:"download_host,omitempty"`
	DownloadTokenPresent bool     `json:"download_token_present"`
	Ready                bool     `json:"ready"`
	FirstSeenAt          string   `json:"first_seen_at,omitempty"`
}

type StreamingPluginAssignment struct {
	AssignmentID string
	PluginID     string
	Name         string
	Entrypoint   string
	Runtime      string
	Capabilities []string
}

type pluginExecutionMode string

const (
	pluginExecutionModeScheduled pluginExecutionMode = "scheduled"
	pluginExecutionModeStreaming pluginExecutionMode = "streaming"
	pluginExecutionModeAction    pluginExecutionMode = "action"
)
