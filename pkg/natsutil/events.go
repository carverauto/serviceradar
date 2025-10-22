package natsutil

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/rs/zerolog"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// EventPublisher provides methods for publishing CloudEvents to NATS JetStream.
type EventPublisher struct {
	js       jetstream.JetStream
	stream   string
	subjects []string
	logger   zerolog.Logger
}

// NewEventPublisher creates a new EventPublisher for the specified stream.
func NewEventPublisher(js jetstream.JetStream, streamName string, subjects []string) *EventPublisher {
	return &EventPublisher{
		js:       js,
		stream:   streamName,
		subjects: append([]string(nil), subjects...),
		logger:   logger.WithComponent("natsutil.events"),
	}
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

	eventBytes, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to marshal poller health event: %w", err)
	}

	// Publish to NATS with the event subject
	ack, err := p.js.Publish(ctx, event.Subject, eventBytes)
	if err != nil && isStreamMissingErr(err) {
		if ensureErr := p.ensureStream(ctx, event.Subject); ensureErr != nil {
			return fmt.Errorf("failed to ensure stream for poller health event: %w", ensureErr)
		}

		ack, err = p.js.Publish(ctx, event.Subject, eventBytes)
	}

	if err != nil {
		return fmt.Errorf("failed to publish poller health event: %w", err)
	}

	// Log the sequence number for debugging
	p.logger.Debug().
		Str("event_id", event.ID).
		Str("subject", event.Subject).
		Uint64("sequence", ack.Sequence).
		Msg("Published event")

	return nil
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
