// Command replayer serves locked demo clips as looping RTSP paths.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/carverauto/serviceradar/demo/rtsp-replayer"
)

func main() {
	os.Exit(run())
}

func run() int {
	fetchOnly := flag.Bool("fetch-only", false, "fetch and verify clips, then exit without serving")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg, err := replayer.ConfigFromEnv()
	if err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "replayer: %v\n", err)
		return 1
	}
	return replayer.Run(ctx, cfg, *fetchOnly, os.Stdout, os.Stderr)
}
