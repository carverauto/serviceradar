// Command k8s-inventory lists or continuously publishes public Kubernetes
// endpoint ownership.
//
//	k8s-inventory snapshot --cluster-id demo --ip 198.51.100.10 --port 22
//	k8s-inventory run   # long-running; config from env (see package docs)
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/k8sinventory"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

var errClusterIDFlagRequired = errors.New("--cluster-id is required")

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "snapshot":
		if err := runSnapshot(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "k8s-inventory snapshot: %v\n", err)
			os.Exit(1)
		}
	case "run":
		if err := runDaemon(os.Args[2:]); err != nil {
			log.Printf("k8s-inventory run: %v", err)
			os.Exit(1)
		}
	case "help", "-h", "--help":
		usage()
	default:
		// Allow bare `k8s-inventory` with env as `run` for container entrypoint convenience.
		if os.Args[1] == "snapshot" || os.Args[1] == "run" {
			usage()
			os.Exit(2)
		}
		// If first arg looks like a flag, treat as run with flags unsupported — require subcommand.
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `Usage:
  k8s-inventory snapshot [flags]
  k8s-inventory run

snapshot flags:
  --cluster-id string   Cluster identifier (required)
  --kubeconfig string   Path to kubeconfig
  --namespace string    Limit to one namespace
  --ip string           Filter by public IP
  --hostname string     Filter by public hostname
  --port int            Filter by port (0 = any)
  --no-gateway          Skip Gateway API listing
  --hints-only          Print only correlation_hints
  --timeout duration    API timeout (default 30s)

run:
  Configuration is read from environment variables (CLUSTER_ID required).
  PUBLISH_MODE=nats|stdout|none (default nats)
  See go/pkg/k8sinventory/README.md

Examples:
  k8s-inventory snapshot --cluster-id demo --ip 198.51.100.10 --port 22
  PUBLISH_MODE=stdout CLUSTER_ID=demo k8s-inventory run
`)
}

func runDaemon(args []string) error {
	if len(args) > 0 {
		// optional -h
		fs := flag.NewFlagSet("run", flag.ContinueOnError)
		_ = fs.Parse(args)
	}
	cfg, err := k8sinventory.LoadConfigFromEnv()
	if err != nil {
		return err
	}
	rt, err := k8sinventory.NewRuntime(cfg)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	return rt.Run(ctx)
}

func runSnapshot(args []string) error {
	fs := flag.NewFlagSet("snapshot", flag.ContinueOnError)
	clusterID := fs.String("cluster-id", "", "cluster identifier")
	kubeconfig := fs.String("kubeconfig", "", "kubeconfig path")
	namespace := fs.String("namespace", "", "namespace filter")
	ip := fs.String("ip", "", "filter IP")
	hostname := fs.String("hostname", "", "filter hostname")
	port := fs.Int("port", 0, "filter port")
	noGateway := fs.Bool("no-gateway", false, "skip Gateway API")
	hintsOnly := fs.Bool("hints-only", false, "print correlation hints only")
	timeout := fs.Duration("timeout", 30*time.Second, "timeout")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *clusterID == "" {
		return errClusterIDFlagRequired
	}

	cfg, err := restConfig(*kubeconfig)
	if err != nil {
		return err
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return fmt.Errorf("kubernetes client: %w", err)
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return fmt.Errorf("dynamic client: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	opts := k8sinventory.SnapshotOptions{
		ClusterID:        *clusterID,
		EnableGatewayAPI: !*noGateway,
	}
	if *namespace != "" {
		opts.Namespaces = []string{*namespace}
	}

	lister := &k8sinventory.ClientLister{
		Client:     client,
		Dynamic:    dyn,
		GatewayAPI: !*noGateway,
	}

	snap, err := k8sinventory.SnapshotFromLister(ctx, lister, opts)
	if err != nil {
		return err
	}

	if *ip != "" || *hostname != "" || *port != 0 {
		snap.Endpoints = k8sinventory.FindByPublicAddr(snap.Endpoints, *ip, *hostname, int32(*port))
		snap.Hints = k8sinventory.FindHints(snap.Hints, *ip, int32(*port))
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if *hintsOnly {
		return enc.Encode(snap.Hints)
	}
	return enc.Encode(snap)
}

func restConfig(kubeconfig string) (*rest.Config, error) {
	if kubeconfig == "" {
		kubeconfig = os.Getenv("KUBECONFIG")
	}
	if kubeconfig == "" {
		if home, err := os.UserHomeDir(); err == nil {
			candidate := filepath.Join(home, ".kube", "config")
			if _, err := os.Stat(candidate); err == nil {
				kubeconfig = candidate
			}
		}
	}
	if kubeconfig != "" {
		return clientcmd.BuildConfigFromFlags("", kubeconfig)
	}
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("no kubeconfig and not in-cluster: %w", err)
	}
	return cfg, nil
}
