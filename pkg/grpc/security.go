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

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

const (
	SecurityModeNone   models.SecurityMode = "none"
	SecurityModeSpiffe models.SecurityMode = "spiffe"
	SecurityModeMTLS   models.SecurityMode = "mtls"
)

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

// MTLSProvider implements SecurityProvider with mutual TLS.
type MTLSProvider struct {
	config      *models.SecurityConfig
	clientCreds credentials.TransportCredentials
	serverCreds credentials.TransportCredentials
	closeOnce   sync.Once
	needsClient bool
	needsServer bool
}

func NewMTLSProvider(config *models.SecurityConfig) (*MTLSProvider, error) {
	if config == nil {
		return nil, errSecurityConfigRequired
	}

	provider := &MTLSProvider{
		config: config,
	}

	// Determine which credentials are needed based on role
	switch config.Role {
	case models.RolePoller:
		provider.needsClient = true // For connecting to Agent and Cloud
		provider.needsServer = true // For health check endpoints
	case models.RoleAgent:
		provider.needsClient = true // For connecting to checkers
		provider.needsServer = true // For accepting poller connections
	case models.RoleCloud:
		provider.needsServer = true // Only accepts connections
	case models.RoleChecker:
		provider.needsServer = true // Only accepts connections
	default:
		return nil, fmt.Errorf("%w: %s", errInvalidServiceRole, config.Role)
	}

	log.Printf("Initializing mTLS provider - Role: %s, NeedsClient: %v, NeedsServer: %v",
		config.Role, provider.needsClient, provider.needsServer)

	// Load only the needed credentials
	var err error
	if provider.needsClient {
		provider.clientCreds, err = loadClientCredentials(config)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errFailedToLoadClientCreds, err)
		}
	}

	if provider.needsServer {
		provider.serverCreds, err = loadServerCredentials(config)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errFailedToLoadServerCreds, err)
		}
	}

	return provider, nil
}

func (p *MTLSProvider) Close() error {
	var err error

	p.closeOnce.Do(func() {
		// Cleanup if needed
	})

	return err
}

func loadClientCredentials(config *models.SecurityConfig) (credentials.TransportCredentials, error) {
	log.Printf("Loading client credentials from %s", config.CertDir)

	// Load client certificate and key
	clientCert := filepath.Join(config.CertDir, "client.pem")
	clientKey := filepath.Join(config.CertDir, "client-key.pem")

	certificate, err := tls.LoadX509KeyPair(clientCert, clientKey)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToLoadClientCert, err)
	}

	// Load CA certificate
	caFile := filepath.Join(config.CertDir, "root.pem")

	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToReadCACert, err)
	}

	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("%w: %w", errFailedToAppendCACert, err)
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{certificate},
		RootCAs:      caPool,
		ServerName:   config.ServerName, // Use the provided server name without port
		MinVersion:   tls.VersionTLS13,
	}

	log.Printf("TLS Config ServerName: %v", tlsConfig.ServerName)

	return credentials.NewTLS(tlsConfig), nil
}

func loadServerCredentials(config *models.SecurityConfig) (credentials.TransportCredentials, error) {
	log.Printf("Loading server credentials from %s", config.CertDir)

	// Load server certificate and key
	serverCert := filepath.Join(config.CertDir, "server.pem")
	serverKey := filepath.Join(config.CertDir, "server-key.pem")

	certificate, err := tls.LoadX509KeyPair(serverCert, serverKey)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToLoadServerCert, err)
	}

	// Load CA certificate for client verification
	caFile := filepath.Join(config.CertDir, "root.pem")

	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToReadCACert, err)
	}

	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("%w: %w", errFailedToAppendCACert, err)
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{certificate},
		ClientCAs:    caPool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS13,
	}

	return credentials.NewTLS(tlsConfig), nil
}

func (p *MTLSProvider) GetClientCredentials(_ context.Context) (grpc.DialOption, error) {
	if !p.needsClient {
		return nil, errServiceNotClient
	}

	return grpc.WithTransportCredentials(p.clientCreds), nil
}

func (p *MTLSProvider) GetServerCredentials(context.Context) (grpc.ServerOption, error) {
	if !p.needsServer {
		return nil, errServiceNotServer
	}

	return grpc.Creds(p.serverCreds), nil
}

// SpiffeProvider implements SecurityProvider using SPIFFE workload API.
type SpiffeProvider struct {
	config    *models.SecurityConfig
	client    *workloadapi.Client
	source    *workloadapi.X509Source
	closeOnce sync.Once
}

func NewSpiffeProvider(ctx context.Context, config *models.SecurityConfig) (*SpiffeProvider, error) {
	if config.WorkloadSocket == "" {
		config.WorkloadSocket = "unix:/run/spire/sockets/agent.sock"
	}

	// Create new workload API client
	client, err := workloadapi.New(
		context.Background(),
		workloadapi.WithAddr(config.WorkloadSocket),
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedWorkloadAPIClient, err)
	}

	// Create X.509 source
	source, err := workloadapi.NewX509Source(
		ctx,
		workloadapi.WithClient(client),
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToCreateX509Source, err)
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
		return nil, fmt.Errorf("%w: %w", errInvalidServerSPIFFEID, err)
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
			return nil, fmt.Errorf("%w: %w", errInvalidTrustDomain, err)
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
func NewSecurityProvider(_ context.Context, config *models.SecurityConfig) (SecurityProvider, error) {
	if config == nil {
		log.Printf("No security config provided, using no security")
		return &NoSecurityProvider{}, nil
	}

	log.Printf("Creating security provider with mode: %s", config.Mode)

	switch config.Mode {
	case SecurityModeNone:
		return &NoSecurityProvider{}, nil
	case SecurityModeMTLS:
		return NewMTLSProvider(config)
	default:
		return nil, fmt.Errorf("%w: %s", errUnknownSecurityMode, config.Mode)
	}
}
