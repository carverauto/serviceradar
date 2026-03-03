package trivysidecar

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"
	"sync/atomic"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

var (
	errNATSConnectionClosed        = errors.New("nats connection is closed")
	errNATSClientCertKeyPairNeeded = errors.New("NATS_CERTFILE and NATS_KEYFILE must be set together")
	errNATSJetStreamUnavailable    = errors.New("jetstream publish context is unavailable")
	errNATSCAParsingFailed         = errors.New("failed to parse CA certificate")
)

// Publisher sends messages to NATS subjects.
type Publisher interface {
	Publish(ctx context.Context, subject string, payload []byte) error
	Close()
	IsConnected() bool
}

// NATSPublisher publishes messages directly into JetStream.
type NATSPublisher struct {
	nc *nats.Conn
	js jetstream.JetStream

	streamName string
	connected  atomic.Bool
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
		return nil, fmt.Errorf("init JetStream client: %w", err)
	}

	publisher := &NATSPublisher{
		nc:         nc,
		js:         js,
		streamName: cfg.NATSStreamName,
	}
	publisher.connected.Store(nc.IsConnected())

	return publisher, nil
}

func (p *NATSPublisher) Publish(ctx context.Context, subject string, payload []byte) error {
	if p == nil || p.nc == nil || p.js == nil {
		return errNATSJetStreamUnavailable
	}

	if p.nc.IsClosed() {
		p.connected.Store(false)
		return errNATSConnectionClosed
	}

	_, err := p.js.Publish(ctx, subject, payload)
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
