package grpc

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

const (
	certManagerPerms = 0700
)

var (
	errMissingCerts = fmt.Errorf("missing certificates")
)

// CertificateManager helps manage TLS certificates.
type CertificateManager struct {
	config *models.SecurityConfig
}

func NewCertificateManager(config *models.SecurityConfig) *CertificateManager {
	return &CertificateManager{config: config}
}

func (cm *CertificateManager) EnsureCertificateDirectory() error {
	return os.MkdirAll(cm.config.CertDir, certManagerPerms)
}

func (cm *CertificateManager) ValidateCertificates(mutual bool) error {
	required := []string{"ca.crt", "server.crt", "server.key"}
	if mutual {
		required = append(required, "client.crt", "client.key")
	}

	var missing []string

	for _, file := range required {
		path := filepath.Join(cm.config.CertDir, file)

		if _, err := os.Stat(path); os.IsNotExist(err) {
			missing = append(missing, file)
		}
	}

	if len(missing) > 0 {
		return fmt.Errorf("%w %s", errMissingCerts, strings.Join(missing, ", "))
	}

	return nil
}

// Example usage:
/*
type ServerConfig struct {
	Security *SecurityConfig
	// ... other config fields
}

func NewServer(config *ServerConfig) (*Server, error) {
	provider, err := NewSecurityProvider(config.Security)
	if err != nil {
		return nil, fmt.Errorf("failed to create security provider: %w", err)
	}

	creds, err := provider.GetServerCredentials(context.Background())
	if err != nil {
		return nil, fmt.Errorf("failed to get server credentials: %w", err)
	}

	server := grpc.NewServer(creds)
	// ... rest of server setup

	return &Server{
		provider: provider,
		server:   server,
	}, nil
}

type Server struct {
	provider SecurityProvider
	server   *grpc.Server
}

func (s *Server) Stop() {
	if s.server != nil {
		s.server.GracefulStop()
	}
	if s.provider != nil {
		_ = s.provider.Close()
	}
}

*/
