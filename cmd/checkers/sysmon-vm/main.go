package main

import (
	"context"
	"flag"
	"fmt"
	"log"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/checker/sysmonvm"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/cpufreq"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("sysmon-vm checker failed: %v", err)
	}
}

func run() error {
	configPath := flag.String("config", "/etc/serviceradar/checkers/sysmon-vm.json", "Path to sysmon-vm config file")
	flag.Parse()

	ctx := context.Background()

	cfgLoader := config.NewConfig(nil)

	var cfg sysmonvm.Config
	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

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
