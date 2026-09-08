package trivysidecar

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

var (
	errNATSConnectionClosed        = errors.New("nats connection is closed")
	errNATSClientCertKeyPairNeeded = errors.New("NATS_CERTFILE and NATS_KEYFILE must be set together")
	errNATSPublisherUnavailable    = errors.New("publisher connection is unavailable")
	errNATSCAParsingFailed         = errors.New("failed to parse CA certificate")
)

// Publisher sends messages to NATS subjects.
type Publisher interface {
	Publish(ctx context.Context, subject string, payload []byte) error
	Close()
	IsConnected() bool
}

// NATSPublisher publishes messages to NATS subjects.
type NATSPublisher struct {
	nc            *nats.Conn
	js            jetstream.JetStream
	streamName    string
	streamSubject string
	connected     atomic.Bool
}

func NewNATSPublisher(cfg Config) (*NATSPublisher, error) {
	opts, err := buildNATSOptions(cfg)
	if err != nil {
		return nil, err
	}

	nc, err := nats.Connect(cfg.NATSHostPort, opts...)
	if err != nil {
		return nil, fmt.Errorf("connect NATS: %w", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("create JetStream context: %w", err)
	}

	streamName := strings.TrimSpace(cfg.NATSStreamName)
	if streamName == "" {
		streamName = defaultNATSStreamName
	}

	subjectPrefix := strings.TrimSpace(cfg.NATSSubjectPrefix)
	if subjectPrefix == "" {
		subjectPrefix = defaultNATSSubjectPrefix
	}

	publisher := &NATSPublisher{
		nc:            nc,
		js:            js,
		streamName:    streamName,
		streamSubject: subjectPrefix + ".>",
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.PublishTimeout)
	if cfg.PublishTimeout <= 0 {
		cancel()
		ctx, cancel = context.WithTimeout(context.Background(), defaultPublishTimeout)
	}
	defer cancel()

	if err := publisher.ensureStream(ctx, publisher.streamSubject); err != nil {
		nc.Close()
		return nil, err
	}

	publisher.connected.Store(nc.IsConnected())

	return publisher, nil
}

func (p *NATSPublisher) Publish(ctx context.Context, subject string, payload []byte) error {
	if p == nil || p.nc == nil {
		return errNATSPublisherUnavailable
	}

	if p.nc.IsClosed() {
		p.connected.Store(false)
		return errNATSConnectionClosed
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	_, err := p.js.Publish(ctx, subject, payload)
	if err != nil {
		if ensureErr := p.ensureStream(ctx, subject); ensureErr == nil {
			_, err = p.js.Publish(ctx, subject, payload)
		} else {
			err = fmt.Errorf("%w; additionally failed to ensure stream: %w", err, ensureErr)
		}
	}

	if err != nil {
		p.connected.Store(p.nc.IsConnected())
		return fmt.Errorf("publish to %s: %w", subject, err)
	}

	p.connected.Store(true)
	return nil
}

func (p *NATSPublisher) Close() {
	if p == nil || p.nc == nil {
		return
	}

	p.connected.Store(false)
	p.nc.Close()
}

func (p *NATSPublisher) IsConnected() bool {
	if p == nil || p.nc == nil {
		return false
	}

	return p.connected.Load() && p.nc.IsConnected()
}

func (p *NATSPublisher) ensureStream(ctx context.Context, subject string) error {
	if p == nil || p.js == nil {
		return errNATSPublisherUnavailable
	}

	subject = strings.TrimSpace(subject)
	if subject == "" {
		subject = p.streamSubject
	}

	stream, err := p.js.Stream(ctx, p.streamName)
	if err != nil {
		if errors.Is(err, jetstream.ErrStreamNotFound) || errors.Is(err, nats.ErrStreamNotFound) {
			_, createErr := p.js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
				Name:     p.streamName,
				Subjects: []string{p.streamSubject},
				Storage:  jetstream.FileStorage,
			})
			if createErr != nil {
				return fmt.Errorf("create JetStream stream %s: %w", p.streamName, createErr)
			}

			return nil
		}

		return fmt.Errorf("lookup JetStream stream %s: %w", p.streamName, err)
	}

	info, err := stream.Info(ctx)
	if err != nil {
		return fmt.Errorf("read JetStream stream %s info: %w", p.streamName, err)
	}

	if streamSubjectsCover(info.Config.Subjects, subject) &&
		streamSubjectsCover(info.Config.Subjects, p.streamSubject) {
		return nil
	}

	cfg := info.Config
	cfg.Subjects = appendCoveredSubjects(cfg.Subjects, p.streamSubject)
	cfg.Subjects = appendCoveredSubjects(cfg.Subjects, subject)

	if _, err := p.js.CreateOrUpdateStream(ctx, cfg); err != nil {
		return fmt.Errorf("update JetStream stream %s subjects: %w", p.streamName, err)
	}

	return nil
}

func appendCoveredSubjects(subjects []string, subject string) []string {
	if subject == "" || streamSubjectsCover(subjects, subject) {
		return subjects
	}

	return append(subjects, subject)
}

func streamSubjectsCover(subjects []string, subject string) bool {
	for _, existing := range subjects {
		if existing == subject {
			return true
		}

		if strings.HasSuffix(existing, ".>") {
			prefix := strings.TrimSuffix(existing, ">")
			if strings.HasPrefix(subject, prefix) {
				return true
			}
		}
	}

	return false
}

func buildNATSOptions(cfg Config) ([]nats.Option, error) {
	opts := []nats.Option{
		nats.Name("trivy-sidecar"),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(2 * time.Second),
		nats.RetryOnFailedConnect(true),
	}

	tlsConfig, err := buildTLSConfig(cfg)
	if err != nil {
		return nil, err
	}

	if tlsConfig != nil {
		opts = append(opts, nats.Secure(tlsConfig))
	}

	if cfg.NATSCredsFile != "" {
		opts = append(opts, nats.UserCredentials(cfg.NATSCredsFile))
	}

	return opts, nil
}

func buildTLSConfig(cfg Config) (*tls.Config, error) {
	hasTLSConfig := cfg.NATSCACertFile != "" || cfg.NATSCertFile != "" || cfg.NATSKeyFile != "" || cfg.NATSServerName != "" || cfg.NATSSkipVerify
	if !hasTLSConfig {
		return nil, nil
	}

	if (cfg.NATSCertFile == "") != (cfg.NATSKeyFile == "") {
		return nil, errNATSClientCertKeyPairNeeded
	}

	tlsConfig := &tls.Config{
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: cfg.NATSSkipVerify,
		ServerName:         cfg.NATSServerName,
	}

	if cfg.NATSCACertFile != "" {
		caBytes, err := os.ReadFile(cfg.NATSCACertFile)
		if err != nil {
			return nil, fmt.Errorf("read NATS_CACERTFILE: %w", err)
		}

		roots := x509.NewCertPool()
		if ok := roots.AppendCertsFromPEM(caBytes); !ok {
			return nil, fmt.Errorf("parse NATS_CACERTFILE: %w", errNATSCAParsingFailed)
		}

		tlsConfig.RootCAs = roots
	}

	if cfg.NATSCertFile != "" && cfg.NATSKeyFile != "" {
		cert, err := tls.LoadX509KeyPair(cfg.NATSCertFile, cfg.NATSKeyFile)
		if err != nil {
			return nil, fmt.Errorf("load NATS client certificate: %w", err)
		}

		tlsConfig.Certificates = []tls.Certificate{cert}
	}

	return tlsConfig, nil
}
