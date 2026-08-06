package k8sinventory

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
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
	errPublisherClosed             = errors.New("publisher is closed")
)

// Publisher sends inventory snapshot payloads.
type Publisher interface {
	Publish(ctx context.Context, subject string, payload []byte) error
	Close()
	IsConnected() bool
}

// NoopPublisher discards payloads but reports connected.
type NoopPublisher struct{}

func (NoopPublisher) Publish(context.Context, string, []byte) error { return nil }
func (NoopPublisher) Close()                                        {}
func (NoopPublisher) IsConnected() bool                             { return true }

// StdoutPublisher writes each payload as a JSON line to stdout (local validation).
type StdoutPublisher struct {
	mu sync.Mutex
}

func (p *StdoutPublisher) Publish(_ context.Context, subject string, payload []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, err := fmt.Printf("%s %s\n", subject, string(payload))
	return err
}
func (*StdoutPublisher) Close()            {}
func (*StdoutPublisher) IsConnected() bool { return true }

// RecordingPublisher stores payloads for tests.
//
// The slices are unexported on purpose. Publish runs on the Controller's goroutine while the
// test asserts from its own, so a read has to hold the same mutex the append does. While
// these were exported the tests read `len(rec.Payloads)` directly and `-race` caught it
// against Publish's append: the mutex was already here and was simply bypassed. Routing every
// read through an accessor is what stops that recurring.
type RecordingPublisher struct {
	mu       sync.Mutex
	payloads [][]byte
	subjects []string
	closed   atomic.Bool
}

func (p *RecordingPublisher) Publish(_ context.Context, subject string, payload []byte) error {
	if p.closed.Load() {
		return errPublisherClosed
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	clone := make([]byte, len(payload))
	copy(clone, payload)
	p.payloads = append(p.payloads, clone)
	p.subjects = append(p.subjects, subject)
	return nil
}

// Len reports how many payloads have been published.
func (p *RecordingPublisher) Len() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.payloads)
}

// PayloadAt returns a copy of the i-th payload, or nil when i is out of range. The copy keeps
// a caller from mutating recorded bytes that Publish may hand out again.
func (p *RecordingPublisher) PayloadAt(i int) []byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	if i < 0 || i >= len(p.payloads) {
		return nil
	}
	clone := make([]byte, len(p.payloads[i]))
	copy(clone, p.payloads[i])
	return clone
}

// SubjectAt returns the subject of the i-th payload, or "" when i is out of range.
func (p *RecordingPublisher) SubjectAt(i int) string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if i < 0 || i >= len(p.subjects) {
		return ""
	}
	return p.subjects[i]
}
func (p *RecordingPublisher) Close()            { p.closed.Store(true) }
func (p *RecordingPublisher) IsConnected() bool { return !p.closed.Load() }

// NATSPublisher publishes inventory snapshots to JetStream.
type NATSPublisher struct {
	nc            *nats.Conn
	js            jetstream.JetStream
	streamName    string
	streamSubject string
	connected     atomic.Bool
}

// NewPublisherFromConfig selects a publisher based on cfg.PublishMode.
func NewPublisherFromConfig(cfg Config) (Publisher, error) {
	switch cfg.PublishMode {
	case publishModeNone:
		return NoopPublisher{}, nil
	case publishModeStdout:
		return &StdoutPublisher{}, nil
	case publishModeAgentSpool:
		return NewSpoolPublisher(cfg.SpoolDir)
	case publishModeNATS:
		return NewNATSPublisher(cfg)
	default:
		return nil, errInvalidPublishMode
	}
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
	subjectPrefix := strings.TrimSpace(cfg.Subject)
	if subjectPrefix == "" {
		subjectPrefix = defaultNATSSubjectPrefix
	}
	// Stream subject covers prefix and children.
	streamSubject := subjectPrefix
	if !strings.HasSuffix(streamSubject, ">") {
		streamSubject = subjectPrefix + ".>"
		// Also allow exact subject publish of the prefix itself via dual subjects.
		// We store stream as "inventory.k8s.public_endpoints.>" and also exact.
	}

	publisher := &NATSPublisher{
		nc:            nc,
		js:            js,
		streamName:    streamName,
		streamSubject: streamSubject,
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.PublishTimeout)
	if cfg.PublishTimeout <= 0 {
		cancel()
		ctx, cancel = context.WithTimeout(context.Background(), defaultPublishTimeout)
	}
	defer cancel()

	if err := publisher.ensureStream(ctx, cfg.Subject); err != nil {
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
	subjects := []string{p.streamSubject}
	if s := strings.TrimSpace(subject); s != "" && s != p.streamSubject {
		subjects = append(subjects, s)
	}
	// Prefer a covering wildcard when subject is exact.
	if !strings.Contains(p.streamSubject, ">") {
		subjects = append(subjects, p.streamSubject+".>")
	}

	stream, err := p.js.Stream(ctx, p.streamName)
	if err != nil {
		if errors.Is(err, jetstream.ErrStreamNotFound) || errors.Is(err, nats.ErrStreamNotFound) {
			_, createErr := p.js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
				Name:     p.streamName,
				Subjects: uniqueSubjects(subjects),
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
	cfg := info.Config
	for _, s := range subjects {
		if !streamSubjectsCover(cfg.Subjects, s) {
			cfg.Subjects = append(cfg.Subjects, s)
		}
	}
	if _, err := p.js.CreateOrUpdateStream(ctx, cfg); err != nil {
		return fmt.Errorf("update JetStream stream %s subjects: %w", p.streamName, err)
	}
	return nil
}

func uniqueSubjects(in []string) []string {
	seen := map[string]struct{}{}
	var out []string
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
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
		if existing == ">" {
			return true
		}
	}
	return false
}

func buildNATSOptions(cfg Config) ([]nats.Option, error) {
	opts := []nats.Option{
		nats.Name("serviceradar-k8s-inventory"),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(2 * time.Second),
		nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
			if err != nil {
				log.Printf("k8s-inventory: nats disconnected: %v", err)
			}
		}),
		nats.ReconnectHandler(func(_ *nats.Conn) {
			log.Printf("k8s-inventory: nats reconnected")
		}),
	}

	if cfg.NATSCredsFile != "" {
		opts = append(opts, nats.UserCredentials(cfg.NATSCredsFile))
	}

	tlsConfig, err := buildNATSTLSConfig(cfg)
	if err != nil {
		return nil, err
	}
	if tlsConfig != nil {
		opts = append(opts, nats.Secure(tlsConfig))
	}
	return opts, nil
}

func buildNATSTLSConfig(cfg Config) (*tls.Config, error) {
	hasCert := cfg.NATSCertFile != ""
	hasKey := cfg.NATSKeyFile != ""
	if hasCert != hasKey {
		return nil, errNATSClientCertKeyPairNeeded
	}
	if !hasCert && cfg.NATSCACertFile == "" && !cfg.NATSSkipVerify {
		return nil, nil
	}

	tlsCfg := &tls.Config{
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: cfg.NATSSkipVerify, //nolint:gosec // optional lab mode
		ServerName:         cfg.NATSServerName,
	}
	if cfg.NATSCACertFile != "" {
		pemBytes, err := os.ReadFile(cfg.NATSCACertFile)
		if err != nil {
			return nil, fmt.Errorf("read NATS CA: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pemBytes) {
			return nil, errNATSCAParsingFailed
		}
		tlsCfg.RootCAs = pool
	}
	if hasCert {
		cert, err := tls.LoadX509KeyPair(cfg.NATSCertFile, cfg.NATSKeyFile)
		if err != nil {
			return nil, fmt.Errorf("load NATS client cert: %w", err)
		}
		tlsCfg.Certificates = []tls.Certificate{cert}
	}
	return tlsCfg, nil
}
