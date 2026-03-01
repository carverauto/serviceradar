package cli

import (
	"context"
	"fmt"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/edgeonboarding"
)

// RunEnroll handles the enroll subcommand.
func RunEnroll(cfg *CmdConfig) error {
	token := strings.TrimSpace(cfg.EnrollToken)
	if token == "" {
		return errEnrollTokenRequired
	}

	logf := func(format string, args ...interface{}) {
		fmt.Printf(format+"\n", args...)
	}

	if strings.HasPrefix(token, "edgepkg-v1:") {
		client, err := edgeonboarding.BuildHTTPClient(cfg.EnrollCAFile, cfg.EnrollInsecure)
		if err != nil {
			return err
		}
		opts := edgeonboarding.EnrollOptions{
			Token:         token,
			CoreHost:      cfg.EnrollCoreURL,
			HostIP:        cfg.EnrollHostIP,
			ConfigPath:    cfg.EnrollConfigPath,
			CertDir:       cfg.EnrollCertDir,
			HTTPClient:    client,
			SkipOverwrite: !cfg.EnrollForce,
			Logf:          logf,
		}

		return edgeonboarding.EnrollAgentFromToken(context.Background(), opts)
	}

	client, err := edgeonboarding.BuildHTTPClient(cfg.EnrollCAFile, cfg.EnrollInsecure)
	if err != nil {
		return err
	}
	opts := edgeonboarding.CollectorEnrollOptions{
		Token:         token,
		BaseURL:       cfg.EnrollCoreURL,
		ConfigDir:     cfg.EnrollConfigDir,
		ConfigFile:    cfg.EnrollConfigFile,
		CertsDir:      cfg.EnrollCertDir,
		CredsDir:      cfg.EnrollCredsDir,
		HTTPClient:    client,
		SkipOverwrite: !cfg.EnrollForce,
		Logf:          logf,
	}

	return edgeonboarding.EnrollCollectorFromToken(context.Background(), opts)
}
