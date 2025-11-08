package main

import (
	"context"
	"flag"
	"fmt"
	"log"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/checker/sysmonvm"
	"github.com/carverauto/serviceradar/pkg/config"
	cfgbootstrap "github.com/carverauto/serviceradar/pkg/config/bootstrap"
	"github.com/carverauto/serviceradar/pkg/cpufreq"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("sysmon-vm checker failed: %v", err)
	}
}

func run() error {
	configPath := flag.String("config", "/etc/serviceradar/checkers/sysmon-vm.json", "Path to sysmon-vm config file")
	_ = flag.String("onboarding-token", "", "Edge onboarding token (if provided, triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
	flag.Parse()

	ctx := context.Background()

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

	var cfg sysmonvm.Config
	desc, ok := config.ServiceDescriptorFor("sysmon-vm-checker")
	if !ok {
		return fmt.Errorf("sysmon-vm-checker descriptor missing")
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

	sampleInterval, err := cfg.Normalize()
	if err != nil {
		return fmt.Errorf("invalid sample interval: %w", err)
	}

	logCfg := &logger.Config{
		Level:  "info",
		Output: "stdout",
	}

	componentLogger, err := lifecycle.CreateComponentLogger(ctx, "sysmon-vm", logCfg)
	if err != nil {
		return fmt.Errorf("failed to create component logger: %w", err)
	}

	service := sysmonvm.NewService(componentLogger, sampleInterval)

	bootstrapResult.StartWatch(ctx, componentLogger, &cfg, func() {
		componentLogger.Warn().Msg("sysmon-vm config updated in KV; restart checker to apply changes")
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
		ServiceName:          "sysmon-vm",
	}

	if err := lifecycle.RunServer(ctx, &opts); err != nil {
		return fmt.Errorf("server shutdown: %w", err)
	}

	return nil
}

type samplerService struct{}

func (samplerService) Start(ctx context.Context) error {
	return cpufreq.StartHostfreqSampler(ctx)
}

func (samplerService) Stop(context.Context) error {
	cpufreq.StopHostfreqSampler()
	return nil
}
