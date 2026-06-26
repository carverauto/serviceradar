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

// Package addon defines the language-agnostic contract shared by the agent
// (the go-plugin client) and native add-ons (the go-plugin servers) for issue
// 3425's selectable add-on framework. It carries the HashiCorp go-plugin
// handshake, the clean Go Addon interface, and the gRPC adapters that bridge that
// interface to the generated proto/agent/addon/v1 service. Both the agent-side
// manager (go/pkg/agent/addon) and the author-facing SDK (go/pkg/addon/sdk) import
// this package; neither imports a specific add-on's implementation, preserving the
// base agent's dependency isolation.
package addon

import (
	"context"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	goplugin "github.com/hashicorp/go-plugin"
)

const (
	// ProtocolVersion is the go-plugin protocol version negotiated between the
	// agent and add-ons. Bump on incompatible transport changes.
	ProtocolVersion = 1

	// PluginName is the dispense key under which the Addon service is served.
	PluginName = "addon"

	// magicCookieKey/Value are a basic guard so the agent only treats deliberate
	// add-on binaries as plugins (not a security boundary; AutoMTLS provides that).
	magicCookieKey   = "SERVICERADAR_ADDON_PLUGIN"
	magicCookieValue = "serviceradar-addon-v1"

	// CapabilityNativeTelemetryV1 marks add-ons that can stream telemetry batches
	// to the local agent over AddonService.StreamTelemetry.
	CapabilityNativeTelemetryV1 = "native-telemetry:v1"

	// CapabilityArtifactStagingV1 marks producers that can stage durable
	// artifacts through the local agent and agent-gateway. This capability name is
	// intentionally runtime-neutral and is shared with Wasm producers.
	CapabilityArtifactStagingV1 = "artifact-staging:v1"

	// CommandTypeAddonRunCommand is the generic commandbus command used to invoke
	// native add-on actions through agent-gateway -> agent -> add-on gRPC.
	CommandTypeAddonRunCommand = "addon.run_command"

	// CapabilityOtlpRelayV1 marks add-ons that serve the acked OTLP relay stream
	// over AddonService.RelayOtlp. Unlike native-telemetry:v1 (lossy), frames
	// carry a persistent monotonic relay_id and stay in the add-on's durable
	// spool until the agent acks them after gateway acceptance, giving
	// at-least-once delivery.
	CapabilityOtlpRelayV1 = "otlp-relay:v1"

	// CapabilityMetricFeedV1 marks add-ons that consume the agent's local metric
	// feed over AddonService.StreamMetricFeed to analyze samples at the edge
	// (e.g. per-series anomaly detection) before they are published to the
	// gateway. The agent never opens the feed for an add-on that does not
	// advertise this capability, and the stream is lossy by contract so slow
	// add-ons cannot block collection or gateway publishing.
	CapabilityMetricFeedV1 = "metric-feed:v1"
)

// Handshake is the go-plugin handshake shared by the agent and every add-on.
//
//nolint:gochecknoglobals // go-plugin requires a package-level handshake config shared by the host and every plugin binary.
var Handshake = goplugin.HandshakeConfig{
	ProtocolVersion:  ProtocolVersion,
	MagicCookieKey:   magicCookieKey,
	MagicCookieValue: magicCookieValue,
}

// Addon is the clean Go contract an add-on implements and the agent consumes.
type Addon interface {
	// Info reports the add-on's stable identity, version, and advertised
	// capabilities.
	Info(ctx context.Context) (Info, error)
	// Configure applies operator-selected configuration (validated by the control
	// plane against the add-on's config.schema.json) and returns a stable hash.
	Configure(ctx context.Context, configJSON []byte) (ConfigureResult, error)
	// Health is the readiness probe the agent polls; a non-healthy status carries
	// a bounded degradation reason.
	Health(ctx context.Context) (Health, error)
}

// TelemetrySource is implemented by add-ons that can produce native telemetry.
// Add-ons advertise this support with CapabilityNativeTelemetryV1 in Info.
type TelemetrySource interface {
	StreamTelemetry(ctx context.Context) (<-chan *addonpb.TelemetryBatch, error)
}

// TelemetryClient is implemented by client-side adapters that can drain a
// remote add-on's telemetry stream.
type TelemetryClient interface {
	StreamTelemetry(ctx context.Context) (<-chan *addonpb.TelemetryBatch, error)
}

// StreamEndKind classifies why a client-side stream ended.
type StreamEndKind string

const (
	StreamEndEOF     StreamEndKind = "eof"
	StreamEndContext StreamEndKind = "context"
	StreamEndError   StreamEndKind = "error"
)

// StreamDiagnostic reports the terminal condition observed by a client-side
// stream loop. It is best-effort and non-blocking so diagnostics cannot stall
// the stream path.
type StreamDiagnostic struct {
	Stream string
	Kind   StreamEndKind
	Err    error
}

// StreamDiagnosticsClient is optionally implemented by client-side adapters
// that can report why a remote stream ended.
type StreamDiagnosticsClient interface {
	StreamDiagnostics() <-chan StreamDiagnostic
}

// ArtifactSource is implemented by add-ons that can produce durable artifacts.
// Add-ons advertise this support with CapabilityArtifactStagingV1 in Info.
type ArtifactSource interface {
	StreamArtifacts(ctx context.Context) (<-chan *addonpb.ArtifactUploadChunk, error)
}

// ArtifactClient is implemented by client-side adapters that can drain a remote
// add-on's artifact staging stream.
type ArtifactClient interface {
	StreamArtifacts(ctx context.Context) (<-chan *addonpb.ArtifactUploadChunk, error)
}

const (
	StreamNameTelemetry     = "telemetry"
	StreamNameArtifacts     = "artifacts"
	StreamNameOtlpRelay     = "otlp_relay"
	StreamNameMetricFeed    = "metric_feed"
	StreamNameMetricFeedAck = "metric_feed_ack"

	StreamOperationRecv = "recv"
	StreamOperationSend = "send"
)

// StreamLossEvent reports why an already-open add-on stream ended. EOF is a
// clean remote half-close; Err carries transport or stream send/receive errors.
type StreamLossEvent struct {
	Stream    string
	Operation string
	EOF       bool
	Err       error
}

// StreamLossDiagnostics is optionally implemented by client adapters that can
// report why an opened stream ended after its channel closes.
type StreamLossDiagnostics interface {
	StreamLossEvents() <-chan StreamLossEvent
}

// CommandHandler is implemented by add-ons that can execute bounded commands
// requested through the agent control stream. Add-ons advertise schedule-driven
// command support with CapabilityProducerScheduleV1 in their package manifest.
type CommandHandler interface {
	RunCommand(ctx context.Context, request CommandRequest) (CommandResult, error)
}

// CommandClient is implemented by client-side adapters that can invoke a remote
// add-on command over the local go-plugin gRPC connection.
type CommandClient interface {
	RunCommand(ctx context.Context, request CommandRequest) (CommandResult, error)
}

// OtlpRelaySource is implemented by add-ons that serve the acked OTLP relay
// stream (AddonService.RelayOtlp). Add-ons advertise this support with
// CapabilityOtlpRelayV1 in Info; the agent never opens the stream otherwise.
//
// The add-on emits OtlpRelayFrame messages (persistent monotonic relay_id)
// on the returned channel and consumes cumulative ack watermarks from acks:
// an ack value n confirms every frame with relay_id <= n was accepted by the
// agent-gateway and may be released from the add-on's durable spool. The
// implementation should stop (and close its channel) when ctx is done or
// acks is closed; on a later reconnect it re-sends every unacked frame with
// the original relay_ids.
type OtlpRelaySource interface {
	RelayOtlp(ctx context.Context, acks <-chan uint64) (<-chan *addonpb.OtlpRelayFrame, error)
}

// OtlpRelayClient is implemented by client-side adapters that can drive a
// remote add-on's acked OTLP relay stream. frames yields the add-on's relay
// frames; the caller sends cumulative ack watermarks on acks AFTER the
// agent-gateway accepted the corresponding frames (never before — the ack is
// what releases the add-on's spool). The frames channel is closed when the
// stream ends; the caller should close acks when it stops acking.
type OtlpRelayClient interface {
	RelayOtlp(ctx context.Context) (frames <-chan *addonpb.OtlpRelayFrame, acks chan<- uint64, err error)
}

// MetricFeedSink is implemented by add-ons that consume the local agent metric
// feed. The add-on receives MetricFeedFrame messages from frames and returns
// cumulative ack watermarks on the returned channel once it has accepted every
// frame with feed_id <= watermark.
type MetricFeedSink interface {
	StreamMetricFeed(ctx context.Context, frames <-chan *addonpb.MetricFeedFrame) (<-chan uint64, error)
}

// MetricFeedClient is implemented by client-side adapters that can drive a
// remote add-on's local metric feed (AddonService.StreamMetricFeed). It is the
// data-direction inverse of OtlpRelayClient: the caller (agent) SENDS
// MetricFeedFrame frames (each an encoded MetricBatch) on the returned frames
// channel and reads cumulative ack watermarks on acks for flow control. The
// caller closes frames to half-close the send direction; acks is closed when
// the stream ends. The feed is lossy by contract — the caller should drop
// frames rather than block when an add-on falls behind.
type MetricFeedClient interface {
	StreamMetricFeed(ctx context.Context) (frames chan<- *addonpb.MetricFeedFrame, acks <-chan uint64, err error)
}

type TelemetryBatch = addonpb.TelemetryBatch
type TelemetryRecord = addonpb.TelemetryRecord
type TelemetrySourceInfo = addonpb.TelemetrySource
type TelemetryCounters = addonpb.TelemetryCounters
type TelemetryPayloadKind = addonpb.TelemetryPayloadKind
type ArtifactMetadata = addonpb.ArtifactMetadata
type ArtifactUploadChunk = addonpb.ArtifactUploadChunk
type RunCommandRequest = addonpb.RunCommandRequest
type RunCommandResponse = addonpb.RunCommandResponse
type OtlpRelayFrame = addonpb.OtlpRelayFrame
type OtlpRelayAck = addonpb.OtlpRelayAck
type MetricFeedFrame = addonpb.MetricFeedFrame
type MetricFeedAck = addonpb.MetricFeedAck

// Info describes a running add-on.
type Info struct {
	ID           string
	Version      string
	Capabilities []string
}

// ConfigureResult is returned from a Configure call.
type ConfigureResult struct {
	ConfigHash string
	Accepted   bool
	Error      string
}

// CommandRequest is a generic action invocation delivered to an add-on.
type CommandRequest struct {
	CommandID    string
	CommandType  string
	ActionID     string
	Schema       string
	PayloadJSON  []byte
	DeadlineUnix int64
	Metadata     map[string]string
}

// CommandResult is the add-on's bounded result payload.
type CommandResult struct {
	Success     bool
	Message     string
	PayloadJSON []byte
	Metadata    map[string]string
}

// HealthStatus is the coarse health of an add-on.
type HealthStatus int

const (
	HealthUnspecified HealthStatus = iota
	HealthHealthy
	HealthDegraded
	HealthUnhealthy
)

func (s HealthStatus) String() string {
	switch s {
	case HealthHealthy:
		return "healthy"
	case HealthDegraded:
		return "degraded"
	case HealthUnhealthy:
		return "unhealthy"
	case HealthUnspecified:
		return "unspecified"
	default:
		return "unspecified"
	}
}

// Health is the result of a Health probe.
type Health struct {
	Status            HealthStatus
	Version           string
	DegradationReason string
}

func healthStatusToProto(s HealthStatus) addonpb.HealthResponse_Status {
	switch s {
	case HealthHealthy:
		return addonpb.HealthResponse_STATUS_HEALTHY
	case HealthDegraded:
		return addonpb.HealthResponse_STATUS_DEGRADED
	case HealthUnhealthy:
		return addonpb.HealthResponse_STATUS_UNHEALTHY
	case HealthUnspecified:
		return addonpb.HealthResponse_STATUS_UNSPECIFIED
	default:
		return addonpb.HealthResponse_STATUS_UNSPECIFIED
	}
}

func healthStatusFromProto(s addonpb.HealthResponse_Status) HealthStatus {
	switch s {
	case addonpb.HealthResponse_STATUS_HEALTHY:
		return HealthHealthy
	case addonpb.HealthResponse_STATUS_DEGRADED:
		return HealthDegraded
	case addonpb.HealthResponse_STATUS_UNHEALTHY:
		return HealthUnhealthy
	case addonpb.HealthResponse_STATUS_UNSPECIFIED:
		return HealthUnspecified
	default:
		return HealthUnspecified
	}
}
