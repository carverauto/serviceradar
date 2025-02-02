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

var (
	errFailedToAddCACert   = fmt.Errorf("failed to add CA cert to pool")
	errUnknownSecurityMode = fmt.Errorf("unknown security mode")
)

const (
	SecurityModeNone   SecurityMode = "none"
	SecurityModeTLS    SecurityMode = "tls"
	SecurityModeSpiffe SecurityMode = "spiffe"
	SecurityModeMTLS   SecurityMode = "mtls"
)

// SecurityMode defines the type of security to use.
type SecurityMode string

// SecurityConfig holds common security configuration.
type SecurityConfig struct {
	Mode           SecurityMode `json:"mode"`
	CertDir        string       `json:"cert_dir"`
	ServerName     string       `json:"server_name,omitempty"`
	TrustDomain    string       `json:"trust_domain,omitempty"`    // For SPIFFE
	WorkloadSocket string       `json:"workload_socket,omitempty"` // For SPIFFE
}

func (c *SecurityConfig) String() string {
	return fmt.Sprintf("{mode: %s, cert_dir: %s}", c.Mode, c.CertDir)
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

	log.Printf("Muh server Creds: %v", serverCreds)
	log.Printf("Muh client Creds: %v", clientCreds)

	return &TLSProvider{
		config:      config,
		clientCreds: clientCreds,
		serverCreds: serverCreds,
	}, nil
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

// SpiffeProvider implements SecurityProvider using SPIFFE workload API.
type SpiffeProvider struct {
	config    *SecurityConfig
	client    *workloadapi.Client
	source    *workloadapi.X509Source
	closeOnce sync.Once
}

func NewSpiffeProvider(ctx context.Context, config *SecurityConfig) (*SpiffeProvider, error) {
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
		ctx,
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
func NewSecurityProvider(ctx context.Context, config *SecurityConfig) (SecurityProvider, error) {
	if config == nil {
		log.Printf("No security config provided, using no security")
		return &NoSecurityProvider{}, nil
	}

	log.Printf("Creating security provider with mode: %s, cert_dir: %s", config.Mode, config.CertDir)

	switch config.Mode {
	case SecurityModeNone:
		return &NoSecurityProvider{}, nil

	case SecurityModeTLS:
		log.Printf("Setting up TLS security")
		return NewTLSProvider(config)

	case SecurityModeMTLS:
		log.Printf("Setting up mTLS security")
		return NewMTLSProvider(config)

	case SecurityModeSpiffe:
		log.Printf("Setting up SPIFFE security")
		return NewSpiffeProvider(ctx, config)

	default:
		return nil, fmt.Errorf("%w: %s", errUnknownSecurityMode, config.Mode)
	}
}

func loadTLSCredentials(config *SecurityConfig, isServer bool) (credentials.TransportCredentials, error) {
	// Load CA certificate
	log.Printf("Config: %s", config)
	caFile := filepath.Join(config.CertDir, "ca.crt")
	log.Printf("Loading CA certificate from: %s", caFile)

	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA cert: %w", err)
	}

	certPool := x509.NewCertPool()
	if !certPool.AppendCertsFromPEM(caCert) {
		return nil, errFailedToAddCACert
	}

	// Set up basic TLS config
	tlsConfig := &tls.Config{
		RootCAs:    certPool,
		MinVersion: tls.VersionTLS13,
	}

	// Configure server-side settings
	if isServer {
		serverCertPath := filepath.Join(config.CertDir, "server.crt")
		serverKeyPath := filepath.Join(config.CertDir, "server.key")
		log.Printf("Loading server certificates from: %s, %s", serverCertPath, serverKeyPath)

		cert, err := tls.LoadX509KeyPair(serverCertPath, serverKeyPath)
		if err != nil {
			return nil, fmt.Errorf("failed to load server cert/key: %w", err)
		}

		tlsConfig.Certificates = []tls.Certificate{cert}

		if config.Mode == SecurityModeMTLS {
			tlsConfig.ClientCAs = certPool
			tlsConfig.ClientAuth = tls.RequireAndVerifyClientCert
		}

		return credentials.NewTLS(tlsConfig), nil
	}

	// Client-side configuration
	if config.Mode == SecurityModeMTLS {
		clientCert := filepath.Join(config.CertDir, "client.crt")
		clientKey := filepath.Join(config.CertDir, "client.key")
		log.Printf("Loading client certificates from: %s, %s", clientCert, clientKey)

		clientPair, err := tls.LoadX509KeyPair(clientCert, clientKey)
		if err != nil {
			return nil, fmt.Errorf("failed to load client cert/key: %w", err)
		}

		tlsConfig.Certificates = []tls.Certificate{clientPair}
	}

	if config.ServerName != "" {
		tlsConfig.ServerName = config.ServerName
	}

	return credentials.NewTLS(tlsConfig), nil
}
