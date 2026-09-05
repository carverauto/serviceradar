package k8sinventory

import (
	"context"
	"fmt"
	"log"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// Runtime wires kube clients, informers, publisher, HTTP, and controller.
type Runtime struct {
	cfg        Config
	controller *Controller
	httpServer *HTTPServer
	publisher  Publisher
	watcher    *WatcherLister
}

// NewRuntime builds a full collector runtime from config.
func NewRuntime(cfg Config) (*Runtime, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	restConfig, err := BuildKubeConfig(cfg.KubeConfigPath)
	if err != nil {
		return nil, err
	}

	client, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("create kubernetes client: %w", err)
	}
	dyn, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("create dynamic client: %w", err)
	}

	publisher, err := NewPublisherFromConfig(cfg)
	if err != nil {
		return nil, err
	}

	metrics := NewMetrics()
	// Controller starts with a ClientLister; informers replace ListServices/Slices.
	base := &ClientLister{
		Client:     client,
		Dynamic:    dyn,
		GatewayAPI: cfg.EnableGatewayAPI,
	}

	// Temporary controller so Notify can be wired; lister swapped after informers sync.
	ctrl := NewController(cfg, base, publisher, metrics)

	return &Runtime{
		cfg:        cfg,
		controller: ctrl,
		httpServer: NewHTTPServer(cfg.MetricsAddr, ctrl),
		publisher:  publisher,
	}, nil
}

// Run starts metrics HTTP, core informers, and the rebuild controller.
func (r *Runtime) Run(ctx context.Context) error {
	if r == nil || r.controller == nil {
		return errRuntimeNotInitialized
	}

	log.Printf("k8s-inventory: metrics on %s publish_mode=%s subject=%s gateway_api=%v",
		r.cfg.MetricsAddr, r.cfg.PublishMode, r.cfg.Subject, r.cfg.EnableGatewayAPI)
	r.httpServer.Start()
	defer r.httpServer.Close()
	defer r.publisher.Close()

	// Start informers with Notify callback.
	restConfig, err := BuildKubeConfig(r.cfg.KubeConfigPath)
	if err != nil {
		return err
	}
	client, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		return err
	}
	dyn, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		return err
	}

	watcher, err := StartCoreInformers(ctx, client, r.cfg.Namespaces, r.cfg.Resync, r.controller.Notify, r.cfg.EnableNodes)
	if err != nil {
		return err
	}
	r.watcher = watcher
	defer watcher.Stop()

	// Attach dynamic client for Gateway API list path on rebuild.
	watcher.ClientLister = &ClientLister{
		Client:     client,
		Dynamic:    dyn,
		GatewayAPI: r.cfg.EnableGatewayAPI,
	}
	r.controller.lister = watcher

	return r.controller.Run(ctx)
}

// BuildKubeConfig loads in-cluster or kubeconfig settings.
func BuildKubeConfig(kubeConfigPath string) (*rest.Config, error) {
	if kubeConfigPath != "" {
		cfg, err := clientcmd.BuildConfigFromFlags("", kubeConfigPath)
		if err != nil {
			return nil, fmt.Errorf("build kubeconfig from path: %w", err)
		}
		return cfg, nil
	}
	if cfg, err := rest.InClusterConfig(); err == nil {
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
