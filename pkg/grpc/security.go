/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package grpc

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/carverauto/serviceradar/pkg/models"
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
		provider.needsClient = true // For connecting to Agent and Core
		provider.needsServer = true // For health check endpoints
	case models.RoleAgent:
		provider.needsClient = true // For connecting to checkers
		provider.needsServer = true // For accepting poller connections
	case models.RoleCore:
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
		// No resources to cleanup in current implementation
	})

	return err
}

// loadTLSCredentials loads TLS credentials with customizable parameters
func loadTLSCredentials(
	config *models.SecurityConfig,
	certFile, keyFile string,
	isServer bool,
) (credentials.TransportCredentials, error) {
	log.Printf("Loading %s credentials from %s",
		map[bool]string{false: "client", true: "server"}[isServer],
		config.CertDir)

	// Load certificate and key pair
	certPath := filepath.Join(config.CertDir, certFile)
	keyPath := filepath.Join(config.CertDir, keyFile)

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		errType := map[bool]error{false: errFailedToLoadClientCert, true: errFailedToLoadServerCert}[isServer]

		return nil, fmt.Errorf("%w: %w", errType, err)
	}

	// Load CA certificate
	caCert, err := os.ReadFile(filepath.Join(config.CertDir, "root.pem"))
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToReadCACert, err)
	}

	// Create certificate pool
	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("%w: %w", errFailedToAppendCACert, err)
	}

	// Configure TLS
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	}

	if isServer {
		tlsConfig.ClientCAs = caPool
		tlsConfig.ClientAuth = tls.RequireAndVerifyClientCert
	} else {
		tlsConfig.RootCAs = caPool
		tlsConfig.ServerName = config.ServerName
	}

	return credentials.NewTLS(tlsConfig), nil
}

// loadClientCredentials loads client TLS credentials
func loadClientCredentials(config *models.SecurityConfig) (credentials.TransportCredentials, error) {
	return loadTLSCredentials(config, "client.pem", "client-key.pem", false)
}

// loadServerCredentials loads server TLS credentials
func loadServerCredentials(config *models.SecurityConfig) (credentials.TransportCredentials, error) {
	return loadTLSCredentials(config, "server.pem", "server-key.pem", true)
}

func (p *MTLSProvider) GetClientCredentials(_ context.Context) (grpc.DialOption, error) {
	if !p.needsClient {
		return nil, errServiceNotClient
	}

	return grpc.WithTransportCredentials(p.clientCreds), nil
}

func (p *MTLSProvider) GetServerCredentials(_ context.Context) (grpc.ServerOption, error) {
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

	client, err := workloadapi.New(
		ctx,
		workloadapi.WithAddr(config.WorkloadSocket),
	)

	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedWorkloadAPIClient, err)
	}

	source, err := workloadapi.NewX509Source(
		ctx,
		workloadapi.WithClient(client),
	)

	if err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("%w: %w", errFailedToCreateX509Source, err)
	}

	return &SpiffeProvider{
		config: config,
		client: client,
		source: source,
	}, nil
}

func (p *SpiffeProvider) GetClientCredentials(_ context.Context) (grpc.DialOption, error) {
	serverID, err := spiffeid.FromString(p.config.TrustDomain)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errInvalidServerSPIFFEID, err)
	}

	tlsConfig := tlsconfig.MTLSClientConfig(p.source, p.source, tlsconfig.AuthorizeID(serverID))

	return grpc.WithTransportCredentials(credentials.NewTLS(tlsConfig)), nil
}

func (p *SpiffeProvider) GetServerCredentials(_ context.Context) (grpc.ServerOption, error) {
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
			if e := p.source.Close(); e != nil {
				log.Printf("Failed to close X.509 source: %v", e)

				err = e
			}
		}

		if p.client != nil {
			if e := p.client.Close(); e != nil {
				log.Printf("Failed to close workload client: %v", e)

				err = e
			}
		}
	})

	return err
}

// NewSecurityProvider creates the appropriate security provider based on mode.
func NewSecurityProvider(ctx context.Context, config *models.SecurityConfig) (SecurityProvider, error) {
	if config == nil {
		log.Printf("SECURITY WARNING: No security config provided, using no security")

		return &NoSecurityProvider{}, nil
	}

	// Defensive check: ensure mode is a non-empty string
	if config.Mode == "" {
		log.Printf("SECURITY WARNING: Empty security mode, using no security")

		return &NoSecurityProvider{}, nil
	}

	log.Printf("Creating security provider with mode: %s", config.Mode)

	// Make sure we're comparing case-insensitive strings
	mode := strings.ToLower(string(config.Mode))

	switch models.SecurityMode(mode) {
	case SecurityModeNone:
		log.Printf("Using no security (explicitly configured)")

		return &NoSecurityProvider{}, nil
	case SecurityModeMTLS:
		log.Printf("Initializing mTLS security provider with cert dir: %s", config.CertDir)

		provider, err := NewMTLSProvider(config)
		if err != nil {
			// Log detailed error information for debugging
			log.Printf("ERROR creating mTLS provider: %v", err)

			return nil, fmt.Errorf("%w: %w", errFailedToCreateMTLSProvider, err)
		}

		log.Printf("Successfully created mTLS security provider")

		return provider, nil
	case SecurityModeSpiffe:
		log.Printf("Initializing SPIFFE security provider with socket: %s",
			config.WorkloadSocket)

		return NewSpiffeProvider(ctx, config)
	default:
		log.Printf("ERROR: Unknown security mode: %s", config.Mode)

		return nil, fmt.Errorf("%w: %s", errUnknownSecurityMode, config.Mode)
	}
}
