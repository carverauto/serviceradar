package natsutil

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// getLogLevelForState maps poller states to GELF log levels
func getLogLevelForState(state string) int32 {
	switch state {
	case "unhealthy":
		return 3 // Error
	case "healthy":
		return 6 // Info
	case "unknown":
		return 5 // Notice
	default:
		return 6 // Info
	}
}

// getSeverityForState maps poller states to severity strings
func getSeverityForState(state string) string {
	switch state {
	case "unhealthy":
		return "error"
	case "healthy":
		return "info"
	case "unknown":
		return "notice"
	default:
		return "info"
	}
}


// EventPublisher provides methods for publishing CloudEvents to NATS JetStream.
type EventPublisher struct {
	js     jetstream.JetStream
	stream string
}

// NewEventPublisher creates a new EventPublisher for the specified stream.
func NewEventPublisher(js jetstream.JetStream, streamName string) *EventPublisher {
	return &EventPublisher{
		js:     js,
		stream: streamName,
	}
}

// PublishPollerHealthEvent publishes a poller health event to the events stream.
func (p *EventPublisher) PublishPollerHealthEvent(ctx context.Context, pollerID, previousState, currentState string, data models.PollerHealthEventData) error {
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
	if err != nil {
		return fmt.Errorf("failed to publish poller health event: %w", err)
	}

	// Log the sequence number for debugging
	fmt.Printf("Published event %s to subject %s (seq: %d)\n", event.ID, event.Subject, ack.Sequence)

	return nil
}

// PublishPollerRecoveryEvent publishes a poller recovery event.
func (p *EventPublisher) PublishPollerRecoveryEvent(ctx context.Context, pollerID, sourceIP, partition, remoteAddr string, lastSeen time.Time) error {
	data := models.PollerHealthEventData{
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
func (p *EventPublisher) PublishPollerOfflineEvent(ctx context.Context, pollerID, sourceIP, partition string, lastSeen time.Time) error {
	data := models.PollerHealthEventData{
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
func (p *EventPublisher) PublishPollerFirstSeenEvent(ctx context.Context, pollerID, sourceIP, partition, remoteAddr string, timestamp time.Time) error {
	data := models.PollerHealthEventData{
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
func ConnectWithEventPublisher(ctx context.Context, natsURL, streamName string, opts ...nats.Option) (*EventPublisher, *nats.Conn, error) {
	nc, err := nats.Connect(natsURL, opts...)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to connect to NATS: %w", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, nil, fmt.Errorf("failed to create JetStream context: %w", err)
	}

	// Ensure the stream exists
	_, err = js.Stream(ctx, streamName)
	if err != nil {
		// Try to create the stream if it doesn't exist
		streamConfig := jetstream.StreamConfig{
			Name:     streamName,
			Subjects: []string{fmt.Sprintf("poller.health.*")},
		}

		_, err = js.CreateOrUpdateStream(ctx, streamConfig)
		if err != nil {
			nc.Close()
			return nil, nil, fmt.Errorf("failed to create or get stream %s: %w", streamName, err)
		}
	}

	publisher := NewEventPublisher(js, streamName)

	return publisher, nc, nil
}

// ConnectWithSecurity creates a NATS connection with security configuration.
func ConnectWithSecurity(ctx context.Context, natsURL string, security *models.SecurityConfig, extraOpts ...nats.Option) (*nats.Conn, error) {
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
			fmt.Printf("NATS error: %v\n", err)
		}),
		nats.ConnectHandler(func(nc *nats.Conn) {
			fmt.Printf("Connected to NATS: %s\n", nc.ConnectedUrl())
		}),
		nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
			fmt.Printf("NATS disconnected: %v\n", err)
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			fmt.Printf("NATS reconnected: %s\n", nc.ConnectedUrl())
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
func CreateEventPublisher(ctx context.Context, nc *nats.Conn, streamName string, subjects []string) (*EventPublisher, error) {
	return CreateEventPublisherWithDomain(ctx, nc, "", streamName, subjects)
}

// CreateEventPublisherWithDomain creates an EventPublisher with optional NATS domain support.
func CreateEventPublisherWithDomain(ctx context.Context, nc *nats.Conn, domain, streamName string, subjects []string) (*EventPublisher, error) {
	var js jetstream.JetStream

	var err error

	if domain != "" {
		js, err = jetstream.NewWithDomain(nc, domain)
		if err != nil {
			return nil, fmt.Errorf("failed to create JetStream context with domain %s: %w", domain, err)
		}

		fmt.Printf("Created JetStream context with domain: %s\n", domain)
	} else {
		js, err = jetstream.New(nc)
		if err != nil {
			return nil, fmt.Errorf("failed to create JetStream context: %w", err)
		}
	}

	// Ensure the stream exists
	_, err = js.Stream(ctx, streamName)
	if err != nil {
		// Try to create the stream if it doesn't exist
		if len(subjects) == 0 {
			subjects = []string{"events.poller.*", "events.syslog.*", "events.snmp.*"}
		}

		streamConfig := jetstream.StreamConfig{
			Name:     streamName,
			Subjects: subjects,
		}

		_, err = js.CreateOrUpdateStream(ctx, streamConfig)
		if err != nil {
			return nil, fmt.Errorf("failed to create or get stream %s: %w", streamName, err)
		}

		fmt.Printf("Created NATS JetStream stream: %s\n", streamName)
	}

	return NewEventPublisher(js, streamName), nil
}
