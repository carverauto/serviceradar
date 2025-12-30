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

// EventPublisher provides methods for publishing CloudEvents to NATS JetStream.
type EventPublisher struct {
	js              jetstream.JetStream
	stream          string
	subjects        []string
	logger          zerolog.Logger
	tenantPrefixing bool // Whether to prefix subjects with tenant slug
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

// PublishPollerHealthEvent publishes a poller health event to the events stream.
func (p *EventPublisher) PublishPollerHealthEvent(
	ctx context.Context, _, _, _ string, data *models.PollerHealthEventData) error {
	event := models.CloudEvent{
		SpecVersion:     "1.0",
		ID:              uuid.New().String(),
		Source:          "serviceradar/core",
		Type:            "com.carverauto.serviceradar.poller.health",
		DataContentType: "application/json",
		Subject:         "events.poller.health",
		Time:            &data.Timestamp,
		Data:            data,
	}

	return p.publishEvent(ctx, &event)
}

// PublishPollerRecoveryEvent publishes a poller recovery event.
func (p *EventPublisher) PublishPollerRecoveryEvent(
	ctx context.Context, pollerID, sourceIP, partition, remoteAddr string, lastSeen time.Time) error {
	data := &models.PollerHealthEventData{
		PollerID:       pollerID,
		PreviousState:  "unhealthy",
		CurrentState:   "healthy",
		Timestamp:      time.Now(),
		LastSeen:       lastSeen,
		SourceIP:       sourceIP,
		Partition:      partition,
		RemoteAddr:     remoteAddr,
		RecoveryReason: "status_report_received",
	}

	return p.PublishPollerHealthEvent(ctx, pollerID, "unhealthy", "healthy", data)
}

// PublishPollerOfflineEvent publishes a poller offline event.
func (p *EventPublisher) PublishPollerOfflineEvent(
	ctx context.Context, pollerID, sourceIP, partition string, lastSeen time.Time) error {
	data := &models.PollerHealthEventData{
		PollerID:      pollerID,
		PreviousState: "healthy",
		CurrentState:  "unhealthy",
		Timestamp:     time.Now(),
		LastSeen:      lastSeen,
		SourceIP:      sourceIP,
		Partition:     partition,
		AlertSent:     true,
	}

	return p.PublishPollerHealthEvent(ctx, pollerID, "healthy", "unhealthy", data)
}

// PublishPollerFirstSeenEvent publishes an event when a poller reports for the first time.
func (p *EventPublisher) PublishPollerFirstSeenEvent(
	ctx context.Context, pollerID, sourceIP, partition, remoteAddr string, timestamp time.Time) error {
	data := &models.PollerHealthEventData{
		PollerID:      pollerID,
		PreviousState: "unknown",
		CurrentState:  "healthy",
		Timestamp:     timestamp,
		LastSeen:      timestamp,
		SourceIP:      sourceIP,
		Partition:     partition,
		RemoteAddr:    remoteAddr,
	}

	return p.PublishPollerHealthEvent(ctx, pollerID, "unknown", "healthy", data)
}

// PublishDeviceLifecycleEvent publishes lifecycle changes (delete, restore, etc.) for a device.
func (p *EventPublisher) PublishDeviceLifecycleEvent(ctx context.Context, data *models.DeviceLifecycleEventData) error {
	if data == nil {
		return ErrDeviceLifecycleEventDataNil
	}

	if data.Timestamp.IsZero() {
		data.Timestamp = time.Now().UTC()
	}

	if data.Severity == "" {
		data.Severity = "Medium"
	}

	if data.Level == 0 {
		data.Level = 5
	}

	event := models.CloudEvent{
		SpecVersion:     "1.0",
		ID:              uuid.New().String(),
		Source:          "serviceradar/core",
		Type:            "com.carverauto.serviceradar.device.lifecycle",
		DataContentType: "application/json",
		Subject:         "events.devices.lifecycle",
		Time:            &data.Timestamp,
		Data:            data,
	}

	return p.publishEvent(ctx, &event)
}

func (p *EventPublisher) publishEvent(ctx context.Context, event *models.CloudEvent) error {
	if event == nil {
		return ErrEventPayloadNil
	}

	// Apply tenant prefix if enabled
	subject := p.applyTenantPrefix(ctx, event.Subject)

	eventBytes, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to marshal event %s: %w", event.Type, err)
	}

	ack, err := p.js.Publish(ctx, subject, eventBytes)
	if err != nil && isStreamMissingErr(err) {
		if ensureErr := p.ensureStream(ctx, subject); ensureErr != nil {
			return fmt.Errorf("failed to ensure stream for %s: %w", subject, ensureErr)
		}

		ack, err = p.js.Publish(ctx, subject, eventBytes)
	}

	if err != nil {
		return fmt.Errorf("failed to publish event %s: %w", event.Type, err)
	}

	p.logger.Debug().
		Str("event_id", event.ID).
		Str("subject", subject).
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

// PublishWithTenant publishes an event with an explicit tenant slug.
// This bypasses context-based tenant extraction.
func (p *EventPublisher) PublishWithTenant(
	ctx context.Context, tenantSlug, subject string, data interface{}) error {
	// Build subject with tenant prefix if enabled
	finalSubject := subject
	if p.tenantPrefixing && tenantSlug != "" {
		finalSubject = tenant.PrefixChannelWithSlug(tenantSlug, subject)
	}

	event := models.CloudEvent{
		SpecVersion:     "1.0",
		ID:              uuid.New().String(),
		Source:          "serviceradar/core",
		Type:            "com.carverauto.serviceradar.generic",
		DataContentType: "application/json",
		Subject:         finalSubject,
		Time:            timePtr(time.Now()),
		Data:            data,
	}

	eventBytes, err := json.Marshal(&event)
	if err != nil {
		return fmt.Errorf("failed to marshal event: %w", err)
	}

	ack, err := p.js.Publish(ctx, finalSubject, eventBytes)
	if err != nil && isStreamMissingErr(err) {
		if ensureErr := p.ensureStream(ctx, finalSubject); ensureErr != nil {
			return fmt.Errorf("failed to ensure stream for %s: %w", finalSubject, ensureErr)
		}

		ack, err = p.js.Publish(ctx, finalSubject, eventBytes)
	}

	if err != nil {
		return fmt.Errorf("failed to publish event: %w", err)
	}

	p.logger.Debug().
		Str("event_id", event.ID).
		Str("tenant", tenantSlug).
		Str("subject", finalSubject).
		Uint64("sequence", ack.Sequence).
		Msg("Published event with tenant")

	return nil
}

// timePtr returns a pointer to the given time.
func timePtr(t time.Time) *time.Time {
	return &t
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

	subjects := []string{"events.>", "snmp.traps"}

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
		subjects = []string{"events.poller.*", "events.syslog.*", "events.snmp.*"}
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
