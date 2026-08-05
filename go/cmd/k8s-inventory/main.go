// Command k8s-inventory lists public Kubernetes endpoint ownership as JSON.
//
// This binary is intentionally standalone: no NATS, no ServiceRadar core.
// Use it to prove VIP → Service/Gateway → backend associations against a
// live cluster (or fixtures via unit tests in go/pkg/k8sinventory).
//
//	k8s-inventory snapshot --cluster-id demo
//	k8s-inventory snapshot --cluster-id demo --ip 23.138.124.7 --port 22
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/k8sinventory"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

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
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `Usage:
  k8s-inventory snapshot [flags]

Flags:
  --cluster-id string   Cluster identifier stored on endpoints (required)
  --kubeconfig string   Path to kubeconfig (default: KUBECONFIG or ~/.kube/config; in-cluster if empty fails to file)
  --namespace string    Limit to one namespace (default: all)
  --ip string           Filter endpoints by public IP
  --hostname string     Filter endpoints by public hostname
  --port int            Filter endpoints by port (0 = any)
  --no-gateway          Skip Gateway API listing
  --hints-only          Print only correlation_hints
  --timeout duration    API timeout (default 30s)

Examples:
  k8s-inventory snapshot --cluster-id demo --ip 23.138.124.7 --port 22
  k8s-inventory snapshot --cluster-id demo --hints-only --ip 23.138.124.7
`)
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
		return fmt.Errorf("--cluster-id is required")
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
	// Fall back to in-cluster.
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("no kubeconfig and not in-cluster: %w", err)
	}
	return cfg, nil
}
