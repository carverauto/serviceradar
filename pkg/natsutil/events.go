package natsutil

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/rs/zerolog"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/tenant"
)

const (
	ocsfClassEventLogActivity  = 1008
	ocsfCategorySystemActivity = 1
	ocsfActivityLogCreate      = 1
	ocsfVersion                = "1.7.0"
	ocsfEventsSubject          = "events.ocsf.processed"

	// EnvNATSTenantPrefixEnabled is the environment variable to enable tenant prefixing.
	// When set to "true", all NATS subjects will be prefixed with the tenant slug.
	EnvNATSTenantPrefixEnabled = "NATS_TENANT_PREFIX_ENABLED"

	// DefaultTenant is used when no tenant is found in context and prefixing is enabled.
	DefaultTenant = "default"
)

var (
	// ErrDeviceLifecycleEventDataNil is returned when device lifecycle event data is nil.
	ErrDeviceLifecycleEventDataNil = errors.New("device lifecycle event data is nil")
	// ErrEventPayloadNil is returned when event payload is nil.
	ErrEventPayloadNil = errors.New("event payload is nil")
)

// IsTenantPrefixEnabled returns true if NATS tenant prefixing is enabled via environment.
func IsTenantPrefixEnabled() bool {
	val := os.Getenv(EnvNATSTenantPrefixEnabled)
	return val == "true" || val == "1" || val == "yes"
}

// EventPublisher provides methods for publishing OCSF events to NATS JetStream.
type EventPublisher struct {
	js              jetstream.JetStream
	stream          string
	subjects        []string
	logger          zerolog.Logger
	tenantPrefixing bool // Whether to prefix subjects with tenant slug
}

type ocsfEvent struct {
	ID           string           `json:"id"`
	Time         time.Time        `json:"time"`
	ClassUID     int              `json:"class_uid"`
	CategoryUID  int              `json:"category_uid"`
	TypeUID      int              `json:"type_uid"`
	ActivityID   int              `json:"activity_id"`
	ActivityName string           `json:"activity_name,omitempty"`
	SeverityID   int              `json:"severity_id"`
	Severity     string           `json:"severity,omitempty"`
	Message      string           `json:"message,omitempty"`
	StatusID     *int             `json:"status_id,omitempty"`
	Status       string           `json:"status,omitempty"`
	StatusCode   string           `json:"status_code,omitempty"`
	StatusDetail string           `json:"status_detail,omitempty"`
	Metadata     map[string]any   `json:"metadata,omitempty"`
	Observables  []map[string]any `json:"observables,omitempty"`
	TraceID      string           `json:"trace_id,omitempty"`
	SpanID       string           `json:"span_id,omitempty"`
	Actor        map[string]any   `json:"actor,omitempty"`
	Device       map[string]any   `json:"device,omitempty"`
	SrcEndpoint  map[string]any   `json:"src_endpoint,omitempty"`
	DstEndpoint  map[string]any   `json:"dst_endpoint,omitempty"`
	LogName      string           `json:"log_name,omitempty"`
	LogProvider  string           `json:"log_provider,omitempty"`
	LogLevel     string           `json:"log_level,omitempty"`
	LogVersion   string           `json:"log_version,omitempty"`
	Unmapped     map[string]any   `json:"unmapped,omitempty"`
	RawData      string           `json:"raw_data,omitempty"`
	TenantID     string           `json:"tenant_id,omitempty"`
}

// NewEventPublisher creates a new EventPublisher for the specified stream.
// Tenant prefixing is automatically determined by the NATS_TENANT_PREFIX_ENABLED env var.
func NewEventPublisher(js jetstream.JetStream, streamName string, subjects []string) *EventPublisher {
	return &EventPublisher{
		js:              js,
		stream:          streamName,
		subjects:        append([]string(nil), subjects...),
		logger:          logger.WithComponent("natsutil.events"),
		tenantPrefixing: IsTenantPrefixEnabled(),
	}
}

// NewEventPublisherWithPrefixing creates an EventPublisher with explicit tenant prefix control.
func NewEventPublisherWithPrefixing(
	js jetstream.JetStream, streamName string, subjects []string, enablePrefixing bool) *EventPublisher {
	return &EventPublisher{
		js:              js,
		stream:          streamName,
		subjects:        append([]string(nil), subjects...),
		logger:          logger.WithComponent("natsutil.events"),
		tenantPrefixing: enablePrefixing,
	}
}

// IsTenantPrefixingEnabled returns whether tenant prefixing is enabled for this publisher.
func (p *EventPublisher) IsTenantPrefixingEnabled() bool {
	return p.tenantPrefixing
}

// SetTenantPrefixing enables or disables tenant prefixing.
func (p *EventPublisher) SetTenantPrefixing(enabled bool) {
	p.tenantPrefixing = enabled
}

// PublishGatewayHealthEvent publishes a gateway health event to the events stream.
func (p *EventPublisher) PublishGatewayHealthEvent(
	ctx context.Context, gatewayID, previousState, currentState string, data *models.GatewayHealthEventData) error {
	if data == nil {
		return ErrEventPayloadNil
	}

	if data.GatewayID == "" {
		data.GatewayID = gatewayID
	}
	if data.PreviousState == "" {
		data.PreviousState = previousState
	}
	if data.CurrentState == "" {
		data.CurrentState = currentState
	}
	if data.Timestamp.IsZero() {
		data.Timestamp = time.Now().UTC()
	}

	severityID, severity := severityForState(data.CurrentState)
	message := fmt.Sprintf("Gateway %s state %s -> %s", data.GatewayID, data.PreviousState, data.CurrentState)
	event := buildOCSFEvent(message, data.Timestamp, severityID, severity, data.TenantID)
	event.Unmapped = gatewayHealthUnmapped(data)

	return p.publishEvent(ctx, ocsfEventsSubject, event, event.ID)
}

// PublishGatewayRecoveryEvent publishes a gateway recovery event.
func (p *EventPublisher) PublishGatewayRecoveryEvent(
	ctx context.Context, gatewayID, sourceIP, partition, remoteAddr string, lastSeen time.Time) error {
	data := &models.GatewayHealthEventData{
		GatewayID:      gatewayID,
		PreviousState:  "unhealthy",
		CurrentState:   "healthy",
		Timestamp:      time.Now(),
		LastSeen:       lastSeen,
		SourceIP:       sourceIP,
		Partition:      partition,
		RemoteAddr:     remoteAddr,
		RecoveryReason: "status_report_received",
	}

	return p.PublishGatewayHealthEvent(ctx, gatewayID, "unhealthy", "healthy", data)
}

// PublishGatewayOfflineEvent publishes a gateway offline event.
func (p *EventPublisher) PublishGatewayOfflineEvent(
	ctx context.Context, gatewayID, sourceIP, partition string, lastSeen time.Time) error {
	data := &models.GatewayHealthEventData{
		GatewayID:     gatewayID,
		PreviousState: "healthy",
		CurrentState:  "unhealthy",
		Timestamp:     time.Now(),
		LastSeen:      lastSeen,
		SourceIP:      sourceIP,
		Partition:     partition,
		AlertSent:     true,
	}

	return p.PublishGatewayHealthEvent(ctx, gatewayID, "healthy", "unhealthy", data)
}

// PublishGatewayFirstSeenEvent publishes an event when a gateway reports for the first time.
func (p *EventPublisher) PublishGatewayFirstSeenEvent(
	ctx context.Context, gatewayID, sourceIP, partition, remoteAddr string, timestamp time.Time) error {
	data := &models.GatewayHealthEventData{
		GatewayID:     gatewayID,
		PreviousState: "unknown",
		CurrentState:  "healthy",
		Timestamp:     timestamp,
		LastSeen:      timestamp,
		SourceIP:      sourceIP,
		Partition:     partition,
		RemoteAddr:    remoteAddr,
	}

	return p.PublishGatewayHealthEvent(ctx, gatewayID, "unknown", "healthy", data)
}

// PublishDeviceLifecycleEvent publishes lifecycle changes (delete, restore, etc.) for a device.
func (p *EventPublisher) PublishDeviceLifecycleEvent(ctx context.Context, data *models.DeviceLifecycleEventData) error {
	if data == nil {
		return ErrDeviceLifecycleEventDataNil
	}

	if data.Timestamp.IsZero() {
		data.Timestamp = time.Now().UTC()
	}

	severityID, severity := severityForLifecycle(data)
	message := fmt.Sprintf("Device %s %s", data.DeviceID, data.Action)
	event := buildOCSFEvent(message, data.Timestamp, severityID, severity, data.TenantID)
	event.Unmapped = deviceLifecycleUnmapped(data)

	return p.publishEvent(ctx, ocsfEventsSubject, event, event.ID)
}

func (p *EventPublisher) publishEvent(ctx context.Context, subject string, event *ocsfEvent, eventID string) error {
	if event == nil {
		return ErrEventPayloadNil
	}

	// Apply tenant prefix if enabled
	qualifiedSubject := p.applyTenantPrefix(ctx, subject)

	eventBytes, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to marshal event %s: %w", eventID, err)
	}

	ack, err := p.js.Publish(ctx, qualifiedSubject, eventBytes)
	if err != nil && isStreamMissingErr(err) {
		if ensureErr := p.ensureStream(ctx, qualifiedSubject); ensureErr != nil {
			return fmt.Errorf("failed to ensure stream for %s: %w", qualifiedSubject, ensureErr)
		}

		ack, err = p.js.Publish(ctx, qualifiedSubject, eventBytes)
	}

	if err != nil {
		return fmt.Errorf("failed to publish event %s: %w", eventID, err)
	}

	p.logger.Debug().
		Str("event_id", eventID).
		Str("subject", qualifiedSubject).
		Uint64("sequence", ack.Sequence).
		Msg("Published event")

	return nil
}

// applyTenantPrefix adds the tenant prefix to a subject if prefixing is enabled.
// Extracts tenant from context; falls back to DefaultTenant if not found.
func (p *EventPublisher) applyTenantPrefix(ctx context.Context, subject string) string {
	if !p.tenantPrefixing {
		return subject
	}

	tenantSlug := tenant.SlugFromContext(ctx)
	if tenantSlug == "" {
		tenantSlug = DefaultTenant
	}

	return tenant.PrefixChannelWithSlug(tenantSlug, subject)
}

// ConnectWithEventPublisher creates a NATS connection with JetStream and returns an EventPublisher.
func ConnectWithEventPublisher(
	ctx context.Context, natsURL, streamName string, opts ...nats.Option) (*EventPublisher, *nats.Conn, error) {
	nc, err := nats.Connect(natsURL, opts...)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to connect to NATS: %w", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, nil, fmt.Errorf("failed to create JetStream context: %w", err)
	}

	subjects := []string{ocsfEventsSubject, "logs.>", "otel.traces.>", "otel.metrics.>"}

	stream, err := js.Stream(ctx, streamName)
	if err != nil {
		streamConfig := jetstream.StreamConfig{
			Name:     streamName,
			Subjects: subjects,
		}

		stream, err = js.CreateOrUpdateStream(ctx, streamConfig)
		if err != nil {
			nc.Close()
			return nil, nil, fmt.Errorf("failed to create or get stream %s: %w", streamName, err)
		}
		if info, infoErr := stream.Info(ctx); infoErr == nil && info != nil {
			subjects = append([]string(nil), info.Config.Subjects...)
		}
	} else if info, infoErr := stream.Info(ctx); infoErr == nil && info != nil {
		subjects = append([]string(nil), info.Config.Subjects...)
	}

	publisher := NewEventPublisher(js, streamName, subjects)

	return publisher, nc, nil
}

// ConnectWithSecurity creates a NATS connection with security configuration.
func ConnectWithSecurity(
	_ context.Context, natsURL string, security *models.SecurityConfig, extraOpts ...nats.Option) (*nats.Conn, error) {
	var opts []nats.Option

	// Add TLS configuration if security is configured
	if security != nil {
		tlsConf, err := TLSConfig(security)
		if err != nil {
			return nil, fmt.Errorf("failed to build NATS TLS config: %w", err)
		}

		opts = append(opts,
			nats.Secure(tlsConf),
			nats.RootCAs(security.TLS.CAFile),
			nats.ClientCert(security.TLS.CertFile, security.TLS.KeyFile),
		)
	}

	// Add connection handlers
	opts = append(opts,
		nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, err error) {
			logger.Error().Err(err).Msg("NATS error")
		}),
		nats.ConnectHandler(func(nc *nats.Conn) {
			logger.Info().Str("url", nc.ConnectedUrl()).Msg("Connected to NATS")
		}),
		nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
			logger.Warn().Err(err).Msg("NATS disconnected")
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			logger.Info().Str("url", nc.ConnectedUrl()).Msg("NATS reconnected")
		}),
	)

	// Add any extra options
	opts = append(opts, extraOpts...)

	// Connect to NATS
	nc, err := nats.Connect(natsURL, opts...)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to NATS: %w", err)
	}

	return nc, nil
}

// CreateEventPublisher creates an EventPublisher for an existing NATS connection.
func CreateEventPublisher(
	ctx context.Context, nc *nats.Conn, streamName string, subjects []string) (*EventPublisher, error) {
	return CreateEventPublisherWithDomain(ctx, nc, "", streamName, subjects)
}

// CreateEventPublisherWithDomain creates an EventPublisher with optional NATS domain support.
func CreateEventPublisherWithDomain(
	ctx context.Context, nc *nats.Conn, domain, streamName string, subjects []string) (*EventPublisher, error) {
	var js jetstream.JetStream
	var err error

	if domain != "" {
		js, err = jetstream.NewWithDomain(nc, domain)
		if err != nil {
			return nil, fmt.Errorf("failed to create JetStream context with domain %s: %w", domain, err)
		}

		logger.Info().Str("domain", domain).Msg("Created JetStream context with domain")
	} else {
		js, err = jetstream.New(nc)
		if err != nil {
			return nil, fmt.Errorf("failed to create JetStream context: %w", err)
		}
	}

	if len(subjects) == 0 {
		subjects = []string{ocsfEventsSubject, "logs.>", "otel.traces.>", "otel.metrics.>"}
	}

	streamSubjects := append([]string(nil), subjects...)

	stream, err := js.Stream(ctx, streamName)
	if err != nil {
		streamConfig := jetstream.StreamConfig{
			Name:     streamName,
			Subjects: streamSubjects,
		}

		stream, err = js.CreateOrUpdateStream(ctx, streamConfig)
		if err != nil {
			return nil, fmt.Errorf("failed to create or get stream %s: %w", streamName, err)
		}

		logger.Info().Str("stream", streamName).Msg("Created NATS JetStream stream")
		if info, infoErr := stream.Info(ctx); infoErr == nil && info != nil {
			streamSubjects = append([]string(nil), info.Config.Subjects...)
		}
	} else if info, infoErr := stream.Info(ctx); infoErr == nil && info != nil {
		streamSubjects = append([]string(nil), info.Config.Subjects...)
	}

	return NewEventPublisher(js, streamName, streamSubjects), nil
}

func (p *EventPublisher) ensureStream(ctx context.Context, subject string) error {
	var stream jetstream.Stream
	stream, err := p.js.Stream(ctx, p.stream)
	switch {
	case err == nil:
		info, infoErr := stream.Info(ctx)
		if infoErr != nil {
			return fmt.Errorf("failed to fetch stream info for %s: %w", p.stream, infoErr)
		}

		currentSubjects := append([]string(nil), info.Config.Subjects...)
		updatedSubjects := ensureSubjectList(currentSubjects, subject)

		if len(updatedSubjects) != len(info.Config.Subjects) {
			cfg := info.Config
			cfg.Subjects = updatedSubjects

			stream, err = p.js.CreateOrUpdateStream(ctx, cfg)
			if err != nil {
				return fmt.Errorf("failed to update stream %s subjects: %w", p.stream, err)
			}

			p.logger.Info().
				Str("stream", p.stream).
				Str("subject", subject).
				Msg("Updated JetStream stream subjects for event publishing")
		}
	case errors.Is(err, jetstream.ErrStreamNotFound), errors.Is(err, nats.ErrStreamNotFound):
		configuredSubjects := ensureSubjectList(append([]string(nil), p.subjects...), subject)
		if len(configuredSubjects) == 0 {
			configuredSubjects = []string{subject}
		}

		streamConfig := jetstream.StreamConfig{
			Name:     p.stream,
			Subjects: configuredSubjects,
		}

		stream, err = p.js.CreateOrUpdateStream(ctx, streamConfig)
		if err != nil {
			return fmt.Errorf("failed to create stream %s: %w", p.stream, err)
		}

		p.logger.Info().
			Str("stream", p.stream).
			Msg("Created JetStream stream for event publishing")
	default:
		return fmt.Errorf("failed to lookup stream %s: %w", p.stream, err)
	}

	if stream != nil {
		if info, infoErr := stream.Info(ctx); infoErr == nil && info != nil {
			p.subjects = append([]string(nil), info.Config.Subjects...)
		}
	}

	return nil
}

func ensureSubjectList(subjects []string, subject string) []string {
	if len(subjects) == 0 {
		return []string{subject}
	}

	for _, existing := range subjects {
		if matchesSubject(existing, subject) {
			return subjects
		}
	}

	return append(subjects, subject)
}

func matchesSubject(pattern, subject string) bool {
	if pattern == subject || pattern == ">" {
		return true
	}

	patternTokens := strings.Split(pattern, ".")
	subjectTokens := strings.Split(subject, ".")

	for i, token := range patternTokens {
		if token == ">" {
			return true
		}

		if i >= len(subjectTokens) {
			return false
		}

		if token == "*" {
			continue
		}

		if token != subjectTokens[i] {
			return false
		}
	}

	return len(patternTokens) == len(subjectTokens)
}

func isStreamMissingErr(err error) bool {
	return errors.Is(err, jetstream.ErrStreamNotFound) ||
		errors.Is(err, jetstream.ErrNoStreamResponse) ||
		errors.Is(err, nats.ErrStreamNotFound) ||
		errors.Is(err, nats.ErrNoStreamResponse) ||
		errors.Is(err, nats.ErrNoResponders)
}

func buildOCSFEvent(message string, eventTime time.Time, severityID int, severity string, tenantID string) *ocsfEvent {
	if eventTime.IsZero() {
		eventTime = time.Now().UTC()
	}

	if severity == "" {
		severity = severityName(severityID)
	}

	return &ocsfEvent{
		ID:           uuid.New().String(),
		Time:         eventTime,
		ClassUID:     ocsfClassEventLogActivity,
		CategoryUID:  ocsfCategorySystemActivity,
		TypeUID:      ocsfClassEventLogActivity*100 + ocsfActivityLogCreate,
		ActivityID:   ocsfActivityLogCreate,
		ActivityName: "Create",
		SeverityID:   severityID,
		Severity:     severity,
		Message:      message,
		Metadata:     defaultOCSFMetadata(),
		Actor:        map[string]any{"app_name": "serviceradar-core"},
		LogName:      ocsfEventsSubject,
		LogProvider:  "serviceradar-core",
		TenantID:     tenantID,
	}
}

func defaultOCSFMetadata() map[string]any {
	return map[string]any{
		"version": ocsfVersion,
		"product": map[string]any{
			"vendor_name": "ServiceRadar",
			"name":        "core",
		},
		"logged_time": time.Now().UTC().Format(time.RFC3339Nano),
	}
}

func severityForState(state string) (int, string) {
	switch strings.ToLower(strings.TrimSpace(state)) {
	case "healthy":
		return 1, "Informational"
	case "degraded":
		return 3, "Medium"
	case "unhealthy", "offline":
		return 5, "Critical"
	default:
		return 0, "Unknown"
	}
}

func severityForLifecycle(data *models.DeviceLifecycleEventData) (int, string) {
	if data == nil {
		return 0, "Unknown"
	}

	if data.Severity != "" {
		return severityFromText(data.Severity)
	}

	if data.Level != 0 {
		return severityFromLevel(data.Level)
	}

	return 1, "Informational"
}

func severityFromText(text string) (int, string) {
	switch strings.ToLower(strings.TrimSpace(text)) {
	case "fatal":
		return 6, "Fatal"
	case "critical":
		return 5, "Critical"
	case "error", "high":
		return 4, "High"
	case "warn", "warning", "medium":
		return 3, "Medium"
	case "notice", "low":
		return 2, "Low"
	case "info", "informational":
		return 1, "Informational"
	default:
		return 0, "Unknown"
	}
}

func severityFromLevel(level int32) (int, string) {
	switch level {
	case 0:
		return 6, "Fatal"
	case 1, 2:
		return 5, "Critical"
	case 3:
		return 4, "High"
	case 4:
		return 3, "Medium"
	case 5:
		return 2, "Low"
	case 6, 7:
		return 1, "Informational"
	default:
		return 0, "Unknown"
	}
}

func severityName(id int) string {
	switch id {
	case 1:
		return "Informational"
	case 2:
		return "Low"
	case 3:
		return "Medium"
	case 4:
		return "High"
	case 5:
		return "Critical"
	case 6:
		return "Fatal"
	default:
		return "Unknown"
	}
}

func gatewayHealthUnmapped(data *models.GatewayHealthEventData) map[string]any {
	if data == nil {
		return nil
	}

	unmapped := map[string]any{
		"gateway_id":     data.GatewayID,
		"previous_state": data.PreviousState,
		"current_state":  data.CurrentState,
		"source_ip":      data.SourceIP,
		"remote_addr":    data.RemoteAddr,
		"partition":      data.Partition,
		"alert_sent":     data.AlertSent,
	}

	if data.Host != "" {
		unmapped["host"] = data.Host
	}
	if data.RecoveryReason != "" {
		unmapped["recovery_reason"] = data.RecoveryReason
	}
	if !data.LastSeen.IsZero() {
		unmapped["last_seen"] = data.LastSeen.UTC().Format(time.RFC3339Nano)
	}

	return unmapped
}

func deviceLifecycleUnmapped(data *models.DeviceLifecycleEventData) map[string]any {
	if data == nil {
		return nil
	}

	unmapped := map[string]any{
		"device_id":   data.DeviceID,
		"partition":   data.Partition,
		"action":      data.Action,
		"actor":       data.Actor,
		"reason":      data.Reason,
		"severity":    data.Severity,
		"level":       data.Level,
		"remote_addr": data.RemoteAddr,
	}

	if len(data.Metadata) > 0 {
		unmapped["metadata"] = data.Metadata
	}

	return unmapped
}
