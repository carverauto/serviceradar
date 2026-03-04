package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/carverauto/serviceradar/go/pkg/trivysidecar"
)

func main() {
	os.Exit(run())
}

func run() int {
	cfg, err := trivysidecar.LoadConfigFromEnv()
	if err != nil {
		log.Printf("trivy-sidecar: invalid configuration: %v", err)
		return 1
	}

	runtime, err := trivysidecar.NewRuntime(cfg)
	if err != nil {
		log.Printf("trivy-sidecar: startup failed: %v", err)
		return 1
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := runtime.Run(ctx); err != nil {
		log.Printf("trivy-sidecar: runtime failed: %v", err)
		return 1
	}

	return 0
}
