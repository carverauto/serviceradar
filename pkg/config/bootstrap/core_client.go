package bootstrap

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	coregrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errCoreMTLSConfig         = errors.New("CORE_SEC_MODE=mtls requires CORE_CERT_FILE, CORE_KEY_FILE, and CORE_CA_FILE")
	errUnsupportedCoreSecMode = errors.New("unsupported CORE_SEC_MODE")
)

// BuildCoreDialOptionsFromEnv constructs gRPC dial options for reaching the core service
// using the SPIFFE or mTLS settings provided via environment variables.
func BuildCoreDialOptionsFromEnv(ctx context.Context, role models.ServiceRole, log logger.Logger) ([]grpc.DialOption, coregrpc.SecurityProvider, error) {
	opts := []grpc.DialOption{}

	provider, err := CoreSecurityProviderFromEnv(ctx, role, log)
	if err != nil {
		return nil, nil, err
	}

	if provider != nil {
		creds, credErr := provider.GetClientCredentials(ctx)
		if credErr != nil {
			if provider != nil {
				_ = provider.Close()
			}
			return nil, nil, credErr
		}
		opts = append(opts, creds)
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	return opts, provider, nil
}

// CoreSecurityProviderFromEnv returns a security provider initialized from CORE_* env vars.
func CoreSecurityProviderFromEnv(ctx context.Context, role models.ServiceRole, log logger.Logger) (coregrpc.SecurityProvider, error) {
	mode := strings.ToLower(strings.TrimSpace(os.Getenv("CORE_SEC_MODE")))
	switch mode {
	case "", "none":
		return nil, nil
	case "spiffe":
		workloadSocket := strings.TrimSpace(os.Getenv("CORE_WORKLOAD_SOCKET"))
		if workloadSocket == "" {
			workloadSocket = "unix:/run/spire/sockets/agent.sock"
		}

		conf := &models.SecurityConfig{
			Mode:           "spiffe",
			CertDir:        strings.TrimSpace(os.Getenv("CORE_CERT_DIR")),
			Role:           role,
			TrustDomain:    strings.TrimSpace(os.Getenv("CORE_TRUST_DOMAIN")),
			ServerSPIFFEID: strings.TrimSpace(os.Getenv("CORE_SERVER_SPIFFE_ID")),
			WorkloadSocket: workloadSocket,
		}
		return coregrpc.NewSecurityProvider(ctx, conf, log)
	case "mtls":
		cert := strings.TrimSpace(os.Getenv("CORE_CERT_FILE"))
		key := strings.TrimSpace(os.Getenv("CORE_KEY_FILE"))
		ca := strings.TrimSpace(os.Getenv("CORE_CA_FILE"))
		if cert == "" || key == "" || ca == "" {
			return nil, errCoreMTLSConfig
		}

		conf := &models.SecurityConfig{
			Mode:       "mtls",
			CertDir:    strings.TrimSpace(os.Getenv("CORE_CERT_DIR")),
			Role:       role,
			ServerName: strings.TrimSpace(os.Getenv("CORE_SERVER_NAME")),
			TLS: models.TLSConfig{
				CertFile: cert,
				KeyFile:  key,
				CAFile:   ca,
			},
		}
		return coregrpc.NewSecurityProvider(ctx, conf, log)
	default:
		return nil, fmt.Errorf("%w %q", errUnsupportedCoreSecMode, mode)
	}
}
