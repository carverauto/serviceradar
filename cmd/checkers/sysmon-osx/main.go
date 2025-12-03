package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/checker/sysmonosx"
	"github.com/carverauto/serviceradar/pkg/config"
	cfgbootstrap "github.com/carverauto/serviceradar/pkg/config/bootstrap"
	"github.com/carverauto/serviceradar/pkg/cpufreq"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding/mtls"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errSysmonDescriptorMissing = fmt.Errorf("sysmon-osx-checker descriptor missing")
	errRootPrivilegesRequired  = fmt.Errorf("root privileges required to restart launchd service")
)

const (
	defaultConfigPath    = "/etc/serviceradar/checkers/sysmon-osx.json"
	macOSConfigPath      = "/usr/local/etc/serviceradar/sysmon-osx.json"
	launchdServiceTarget = "system/com.serviceradar.sysmonosx"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("sysmon-osx checker failed: %v", err)
	}
}

func run() error {
	configPath := flag.String("config", defaultConfigPath, "Path to sysmon-osx config file")
	_ = flag.String("onboarding-token", "", "Edge onboarding token (SPIFFE path; triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
	mtlsMode := flag.Bool("mtls", false, "Enable mTLS bootstrap (token or bundle required)")
	mtlsToken := flag.String("token", "", "mTLS onboarding token (edgepkg-v1)")
	mtlsHost := flag.String("host", "", "Core API host for mTLS bundle download (e.g. http://core:8090)")
	mtlsBundlePath := flag.String("bundle", "", "Path to a pre-fetched mTLS bundle (tar.gz or JSON)")
	mtlsCertDir := flag.String("cert-dir", "/etc/serviceradar/certs", "Directory to write mTLS certs/keys")
	mtlsServerName := flag.String("server-name", "sysmon-osx.serviceradar", "Server name to present in mTLS")
	mtlsBootstrapOnly := flag.Bool("mtls-bootstrap-only", false, "Run mTLS bootstrap, persist config, then exit without starting the service")
	flag.Parse()

	configFlag := flag.CommandLine.Lookup("config")
	userProvidedConfig := configFlag != nil && configFlag.Value.String() != configFlag.DefValue
	*configPath = resolveConfigPath(*configPath, userProvidedConfig)

	ctx := context.Background()

	var forcedSecurity *models.SecurityConfig

	if *mtlsMode {
		mtlsCfg, err := mtls.Bootstrap(ctx, &mtls.BootstrapConfig{
			Token:       *mtlsToken,
			Host:        *mtlsHost,
			BundlePath:  *mtlsBundlePath,
			CertDir:     *mtlsCertDir,
			ServerName:  *mtlsServerName,
			ServiceName: "sysmon-osx",
			Role:        models.RoleChecker,
		})
		if err != nil {
			return fmt.Errorf("mTLS bootstrap failed: %w", err)
		}
		forcedSecurity = mtlsCfg
		log.Printf("mTLS bundle installed to %s", *mtlsCertDir)
		persistMTLSConfig(*configPath, forcedSecurity)
		if *mtlsBootstrapOnly {
			log.Printf("mTLS bootstrap-only mode enabled; exiting after writing config")
			if err := restartLaunchdService(ctx); err != nil {
				log.Printf("note: could not restart launchd service: %v", err)
				log.Printf("you may need to manually restart: sudo launchctl kickstart -k %s", launchdServiceTarget)
			}
			return nil
		}
	} else {
		// Try edge onboarding first (checks env vars if flags not set)
		onboardingResult, err := edgeonboarding.TryOnboard(ctx, models.EdgeOnboardingComponentTypeChecker, nil)
		if err != nil {
			return fmt.Errorf("edge onboarding failed: %w", err)
		}

		// If onboarding was performed, use the generated config
		if onboardingResult != nil {
			*configPath = onboardingResult.ConfigPath
			log.Printf("Using edge-onboarded configuration from: %s", *configPath)
			log.Printf("SPIFFE ID: %s", onboardingResult.SPIFFEID)
		}
	}

	var cfg sysmonosx.Config
	desc, ok := config.ServiceDescriptorFor("sysmon-osx-checker")
	if !ok {
		return errSysmonDescriptorMissing
	}
	bootstrapResult, err := cfgbootstrap.Service(ctx, desc, &cfg, cfgbootstrap.ServiceOptions{
		Role:         models.RoleChecker,
		ConfigPath:   *configPath,
		DisableWatch: true,
	})
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}
	defer func() { _ = bootstrapResult.Close() }()

	if forcedSecurity != nil {
		cfg.Security = forcedSecurity
	}

	sampleInterval, err := cfg.Normalize()
	if err != nil {
		return fmt.Errorf("invalid sample interval: %w", err)
	}

	logCfg := &logger.Config{
		Level:  "info",
		Output: "stdout",
	}

	componentLogger, err := lifecycle.CreateComponentLogger(ctx, "sysmon-osx", logCfg)
	if err != nil {
		return fmt.Errorf("failed to create component logger: %w", err)
	}

	service := sysmonosx.NewService(componentLogger, sampleInterval)

	bootstrapResult.StartWatch(ctx, componentLogger, &cfg, func() {
		componentLogger.Warn().Msg("sysmon-osx config updated in KV; restart checker to apply changes")
	})

	register := func(s *grpc.Server) error {
		proto.RegisterAgentServiceServer(s, service)
		return nil
	}

	opts := lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		Service:              samplerService{},
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{register},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
		ServiceName:          "sysmon-osx",
	}

	if err := lifecycle.RunServer(ctx, &opts); err != nil {
		return fmt.Errorf("server shutdown: %w", err)
	}

	return nil
}

type samplerService struct{}

func resolveConfigPath(configPath string, userProvided bool) string {
	if _, err := os.Stat(configPath); err == nil {
		return configPath
	}

	if userProvided {
		return configPath
	}

	fallbacks := []string{macOSConfigPath}
	for _, candidate := range fallbacks {
		if _, err := os.Stat(candidate); err == nil {
			log.Printf("config not found at %s; using %s", configPath, candidate)
			return candidate
		}
	}

	return configPath
}

func persistMTLSConfig(path string, sec *models.SecurityConfig) {
	if sec == nil {
		return
	}

	cfg := loadConfigOrDefault(path)
	cfg.Security = sec

	if _, err := cfg.Normalize(); err != nil {
		log.Printf("unable to normalize config for persistence: %v", err)
		return
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		log.Printf("unable to create config directory %s: %v", filepath.Dir(path), err)
		return
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		log.Printf("unable to marshal config for persistence: %v", err)
		return
	}

	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		log.Printf("unable to write mTLS config to %s: %v", path, err)
		return
	}

	log.Printf("persisted mTLS config to %s", path)
}

func loadConfigOrDefault(path string) *sysmonosx.Config {
	data, err := os.ReadFile(path)
	if err != nil {
		return &sysmonosx.Config{}
	}

	var cfg sysmonosx.Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return &sysmonosx.Config{}
	}

	return &cfg
}

func (samplerService) Start(ctx context.Context) error {
	return cpufreq.StartHostfreqSampler(ctx)
}

func (samplerService) Stop(context.Context) error {
	cpufreq.StopHostfreqSampler()
	return nil
}

// restartLaunchdService restarts the sysmon-osx launchd service on macOS.
// This is called after mTLS bootstrap to apply the new configuration.
func restartLaunchdService(ctx context.Context) error {
	if runtime.GOOS != "darwin" {
		return nil
	}

	// Check if we're running with sufficient privileges
	if os.Geteuid() != 0 {
		return errRootPrivilegesRequired
	}

	log.Printf("restarting launchd service %s to apply new configuration...", launchdServiceTarget)

	// Use launchctl kickstart -k to restart the service
	// The -k flag kills the running service before restarting
	cmd := exec.CommandContext(ctx, "launchctl", "kickstart", "-k", launchdServiceTarget)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("launchctl kickstart failed: %w", err)
	}

	log.Printf("service restart initiated successfully")
	return nil
}
