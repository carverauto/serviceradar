// Package grpc pkg/grpc/security.go provides secure gRPC communication options
package grpc

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"

	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

// SecurityMode defines the type of security to use.
type SecurityMode string

const (
	SecurityModeNone   SecurityMode = "none"
	SecurityModeTLS    SecurityMode = "tls"
	SecurityModeSpiffe SecurityMode = "spiffe"
	SecurityModeMTLS   SecurityMode = "mtls"
)

// SecurityConfig holds common security configuration.
type SecurityConfig struct {
	Mode           SecurityMode
	CertDir        string
	ServerName     string
	TrustDomain    string // For SPIFFE
	WorkloadSocket string // For SPIFFE
}

// NoSecurityProvider implements SecurityProvider with no security (development only).
type NoSecurityProvider struct{}

func (*NoSecurityProvider) GetClientCredentials(context.Context) (grpc.DialOption, error) {
	return grpc.WithTransportCredentials(insecure.NewCredentials()), nil
}

func (*NoSecurityProvider) GetServerCredentials(context.Context) (grpc.ServerOption, error) {
	return grpc.Creds(insecure.NewCredentials()), nil
}

func (*NoSecurityProvider) Close() error {
	return nil
}

// TLSProvider implements SecurityProvider with basic TLS.
type TLSProvider struct {
	config      *SecurityConfig
	clientCreds credentials.TransportCredentials
	serverCreds credentials.TransportCredentials
}

func NewTLSProvider(config *SecurityConfig) (*TLSProvider, error) {
	clientCreds, err := loadTLSCredentials(config, false)
	if err != nil {
		return nil, fmt.Errorf("failed to load client creds: %w", err)
	}

	serverCreds, err := loadTLSCredentials(config, true)
	if err != nil {
		return nil, fmt.Errorf("failed to load server creds: %w", err)
	}

	return &TLSProvider{
		config:      config,
		clientCreds: clientCreds,
		serverCreds: serverCreds,
	}, nil
}

func (p *TLSProvider) GetClientCredentials(context.Context) (grpc.DialOption, error) {
	return grpc.WithTransportCredentials(p.clientCreds), nil
}

func (p *TLSProvider) GetServerCredentials(context.Context) (grpc.ServerOption, error) {
	return grpc.Creds(p.serverCreds), nil
}

func (*TLSProvider) Close() error {
	return nil
}

// MTLSProvider implements SecurityProvider with mutual TLS.
type MTLSProvider struct {
	TLSProvider
}

func NewMTLSProvider(config *SecurityConfig) (*MTLSProvider, error) {
	tlsProvider, err := NewTLSProvider(config)
	if err != nil {
		return nil, err
	}

	return &MTLSProvider{
		TLSProvider: *tlsProvider,
	}, nil
}

// SpiffeProvider implements SecurityProvider using SPIFFE workload API.
type SpiffeProvider struct {
	config    *SecurityConfig
	client    *workloadapi.Client
	source    *workloadapi.X509Source
	closeOnce sync.Once
}

func NewSpiffeProvider(config *SecurityConfig) (*SpiffeProvider, error) {
	if config.WorkloadSocket == "" {
		config.WorkloadSocket = "unix:/run/spire/sockets/agent.sock"
	}

	// Create new workload API client
	client, err := workloadapi.New(
		context.Background(),
		workloadapi.WithAddr(config.WorkloadSocket),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create workload API client: %w", err)
	}

	// Create X.509 source
	source, err := workloadapi.NewX509Source(
		context.Background(),
		workloadapi.WithClient(client),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create X.509 source: %w", err)
	}

	return &SpiffeProvider{
		config: config,
		client: client,
		source: source,
	}, nil
}

func (p *SpiffeProvider) GetClientCredentials(_ context.Context) (grpc.DialOption, error) {
	// Get expected server ID
	serverID, err := spiffeid.FromString(p.config.TrustDomain)
	if err != nil {
		return nil, fmt.Errorf("invalid server SPIFFE ID: %w", err)
	}

	// Create TLS config for client
	tlsConfig := tlsconfig.MTLSClientConfig(p.source, p.source, tlsconfig.AuthorizeID(serverID))

	return grpc.WithTransportCredentials(credentials.NewTLS(tlsConfig)), nil
}

func (p *SpiffeProvider) GetServerCredentials(_ context.Context) (grpc.ServerOption, error) {
	// Create TLS config for server with authorized SPIFFE ID pattern
	// This authorizes any ID in our trust domain
	authorizer := tlsconfig.AuthorizeAny()

	if p.config.TrustDomain != "" {
		trustDomain, err := spiffeid.TrustDomainFromString(p.config.TrustDomain)
		if err != nil {
			return nil, fmt.Errorf("invalid trust domain: %w", err)
		}

		authorizer = tlsconfig.AuthorizeMemberOf(trustDomain)
	}

	tlsConfig := tlsconfig.MTLSServerConfig(p.source, p.source, authorizer)

	return grpc.Creds(credentials.NewTLS(tlsConfig)), nil
}

func (p *SpiffeProvider) Close() error {
	var err error

	p.closeOnce.Do(func() {
		if p.source != nil {
			err = p.source.Close()
			if err != nil {
				log.Printf("Failed to close X.509 source: %v", err)

				return
			}
		}

		if p.client != nil {
			err = p.client.Close()
		}
	})

	return err
}

// NewSecurityProvider creates the appropriate security provider based on mode.
func NewSecurityProvider(config *SecurityConfig) (SecurityProvider, error) {
	switch config.Mode {
	case SecurityModeNone:
		return &NoSecurityProvider{}, nil

	case SecurityModeTLS:
		return NewTLSProvider(config)

	case SecurityModeMTLS:
		return NewMTLSProvider(config)

	case SecurityModeSpiffe:
		return NewSpiffeProvider(config)

	default:
		return nil, fmt.Errorf("unknown security mode: %s", config.Mode)
	}
}

func loadTLSCredentials(config *SecurityConfig, mutual bool) (credentials.TransportCredentials, error) {
	// Load certificate authority
	caFile := filepath.Join(config.CertDir, "ca.crt")

	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA cert: %w", err)
	}

	certPool := x509.NewCertPool()
	if !certPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to add CA cert to pool")
	}

	// Load server certificates
	serverCert := filepath.Join(config.CertDir, "server.crt")
	serverKey := filepath.Join(config.CertDir, "server.key")

	cert, err := tls.LoadX509KeyPair(serverCert, serverKey)
	if err != nil {
		return nil, fmt.Errorf("failed to load server cert/key: %w", err)
	}

	// Configure TLS
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      certPool,
	}

	if mutual {
		tlsConfig.ClientCAs = certPool
		tlsConfig.ClientAuth = tls.RequireAndVerifyClientCert
	}

	return credentials.NewTLS(tlsConfig), nil
}
