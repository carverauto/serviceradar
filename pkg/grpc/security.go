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

// NewMTLSProvider creates a new MTLSProvider with the given configuration.
func NewMTLSProvider(config *models.SecurityConfig) (*MTLSProvider, error) {
	if config == nil {
		return nil, errSecurityConfigRequired
	}

	if config.TLS.CertFile == "" || config.TLS.KeyFile == "" || config.TLS.CAFile == "" {
		log.Printf("ERROR: mTLS mode requires tls.cert_file, tls.key_file, and tls.ca_file to be set in the security config.")

		return nil, fmt.Errorf("%w: missing required TLS file paths in config", errSecurityConfigRequired)
	}

	provider := &MTLSProvider{config: config}
	if err := provider.setCredentialNeeds(); err != nil {
		return nil, err
	}

	log.Printf("Initializing mTLS provider - Role: %s, NeedsClient: %v, NeedsServer: %v",
		config.Role, provider.needsClient, provider.needsServer)

	// Log the paths being used
	log.Printf("mTLS Config Paths: Cert=%s, Key=%s, CA=%s, ClientCA=%s",
		config.TLS.CertFile, config.TLS.KeyFile, config.TLS.CAFile, config.TLS.ClientCAFile)

	if err := provider.loadCredentials(); err != nil {
		return nil, err
	}

	return provider, nil
}

// setCredentialNeeds determines which TLS credentials are required based on the role.
func (p *MTLSProvider) setCredentialNeeds() error {
	roleNeeds := map[models.ServiceRole]struct {
		needsClient, needsServer bool
	}{
		models.RolePoller:  {true, true},  // Client to Agent/Core, Server for health
		models.RoleAgent:   {true, true},  // Client to checkers, Server for Poller
		models.RoleCore:    {false, true}, // Server only
		models.RoleKVStore: {true, true},  // Client to NATS, Server for gRPC
		models.RoleChecker: {false, true}, // Server only
	}

	needs, ok := roleNeeds[p.config.Role]
	if !ok {
		return fmt.Errorf("%w: %s", errInvalidServiceRole, p.config.Role)
	}

	p.needsClient = needs.needsClient
	p.needsServer = needs.needsServer

	return nil
}

// loadCredentials loads the necessary TLS credentials based on role needs.
func (p *MTLSProvider) loadCredentials() error {
	var err error

	if p.needsClient {
		log.Printf("Loading client credentials using paths from config.TLS")

		p.clientCreds, err = loadClientCredentials(p.config)
		if err != nil {
			return fmt.Errorf("%w: %w", errFailedToLoadClientCreds, err)
		}
	}

	if p.needsServer {
		log.Printf("Loading server credentials using paths from config.TLS")

		p.serverCreds, err = loadServerCredentials(p.config)
		if err != nil {
			return fmt.Errorf("%w: %w", errFailedToLoadServerCreds, err)
		}
	}

	return nil
}

func (p *MTLSProvider) Close() error {
	var err error

	p.closeOnce.Do(func() {
		// No resources to cleanup in current implementation
	})

	return err
}

// loadClientCredentials loads client TLS credentials using paths from config.TLS.
func loadClientCredentials(config *models.SecurityConfig) (credentials.TransportCredentials, error) {
	// Use paths directly from config.TLS (should be absolute/normalized)
	certPath := config.TLS.CertFile
	keyPath := config.TLS.KeyFile
	caPath := config.TLS.CAFile

	log.Printf("Loading client certificate from %s and key from %s", certPath, keyPath)

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToLoadClientCert, err)
	}

	log.Printf("Loading client CA certificate from %s", caPath)

	caCert, err := os.ReadFile(caPath)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToReadCACert, err)
	}

	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("%w: failed to parse CA certificate from %s", errFailedToAppendCACert, caPath)
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caPool,
		ServerName:   config.ServerName, // Use server name from config if needed for verification
		MinVersion:   tls.VersionTLS13,
	}

	return credentials.NewTLS(tlsConfig), nil
}

func loadServerCredentials(config *models.SecurityConfig) (credentials.TransportCredentials, error) {
	certPath, keyPath, clientCaPath := normalizePaths(config)

	cert, err := loadServerCert(certPath, keyPath)
	if err != nil {
		return nil, err
	}

	clientCaPool, err := loadClientCAPool(clientCaPath)
	if err != nil {
		return nil, err
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientCAs:    clientCaPool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS13,
	}

	return credentials.NewTLS(tlsConfig), nil
}

// normalizePaths resolves certificate paths based on config.
func normalizePaths(config *models.SecurityConfig) (certPath, keyPath, clientCaPath string) {
	certPath = config.TLS.CertFile
	keyPath = config.TLS.KeyFile
	clientCaPath = config.TLS.ClientCAFile

	if !filepath.IsAbs(certPath) && config.CertDir != "" {
		certPath = filepath.Join(config.CertDir, certPath)
	}

	if !filepath.IsAbs(keyPath) && config.CertDir != "" {
		keyPath = filepath.Join(config.CertDir, keyPath)
	}

	if clientCaPath == "" {
		log.Printf("ClientCAFile not specified, using CAFile (%s) for client verification", config.TLS.CAFile)

		clientCaPath = config.TLS.CAFile
	} else if !filepath.IsAbs(clientCaPath) && config.CertDir != "" {
		clientCaPath = filepath.Join(config.CertDir, clientCaPath)

		log.Printf("Normalized ClientCAFile to: %s", clientCaPath)
	}

	return certPath, keyPath, clientCaPath
}

// loadServerCert loads the server certificate and key pair.
func loadServerCert(certPath, keyPath string) (tls.Certificate, error) {
	log.Printf("Loading server certificate from %s and key from %s", certPath, keyPath)

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("%w: %w", errFailedToLoadServerCert, err)
	}

	return cert, nil
}

// loadClientCAPool loads and parses the client CA certificate into a pool.
func loadClientCAPool(clientCaPath string) (*x509.CertPool, error) {
	log.Printf("Loading server Client CA certificate from %s", clientCaPath)

	clientCaCert, err := os.ReadFile(clientCaPath)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToReadClientCACert, err)
	}

	clientCaPool := x509.NewCertPool()
	if !clientCaPool.AppendCertsFromPEM(clientCaCert) {
		return nil, fmt.Errorf("%w: failed to parse Client CA certificate from %s", errFailedToAppendClientCACert, clientCaPath)
	}

	return clientCaPool, nil
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
