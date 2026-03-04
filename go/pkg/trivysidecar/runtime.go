package trivysidecar

import (
	"context"
	"fmt"
	"log"

	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// Runtime bundles the sidecar service and endpoint server.
type Runtime struct {
	service    *Service
	httpServer *HTTPServer
	publisher  Publisher
}

func NewRuntime(cfg Config) (*Runtime, error) {
	restConfig, err := BuildKubeConfig(cfg.KubeConfigPath)
	if err != nil {
		return nil, err
	}

	dynamicClient, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("create dynamic client: %w", err)
	}

	discoveryClient, err := discovery.NewDiscoveryClientForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("create discovery client: %w", err)
	}

	publisher, err := NewNATSPublisher(cfg)
	if err != nil {
		return nil, err
	}

	service := NewService(cfg, discoveryClient, dynamicClient, publisher, NewMetrics())
	httpServer := NewHTTPServer(cfg.MetricsAddr, service)

	return &Runtime{
		service:    service,
		httpServer: httpServer,
		publisher:  publisher,
	}, nil
}

func (r *Runtime) Run(ctx context.Context) error {
	if r == nil || r.service == nil {
		return nil
	}

	log.Printf("trivy-sidecar: starting metrics endpoint on %s", r.httpServer.httpServer.Addr)
	r.httpServer.Start()
	defer r.httpServer.Close()
	defer r.publisher.Close()

	return r.service.Run(ctx)
}

func BuildKubeConfig(kubeConfigPath string) (*rest.Config, error) {
	if kubeConfigPath != "" {
		cfg, err := clientcmd.BuildConfigFromFlags("", kubeConfigPath)
		if err != nil {
			return nil, fmt.Errorf("build kubeconfig from path: %w", err)
		}

		return cfg, nil
	}

	cfg, err := rest.InClusterConfig()
	if err == nil {
		return cfg, nil
	}

	fallbackCfg, fallbackErr := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		clientcmd.NewDefaultClientConfigLoadingRules(),
		&clientcmd.ConfigOverrides{},
	).ClientConfig()
	if fallbackErr != nil {
		return nil, fmt.Errorf("build fallback kubeconfig: %w", fallbackErr)
	}

	return fallbackCfg, nil
}
