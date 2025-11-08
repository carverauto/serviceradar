package bootstrap

import (
	"context"
	"errors"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// ServiceOptions controls how a service configuration is loaded and watched.
type ServiceOptions struct {
	Role         models.ServiceRole
	ConfigPath   string
	Logger       logger.Logger
	OnReload     func()
	DisableWatch bool
}

// Result contains helpers returned from Service.
type Result struct {
	manager    *config.KVManager
	descriptor config.ServiceDescriptor
}

// Close closes the underlying KV manager if it was created.
func (r *Result) Close() error {
	if r == nil || r.manager == nil {
		return nil
	}

	return r.manager.Close()
}

// StartWatch starts watching the descriptor's KV key using the provided logger.
// If the manager is nil, this is a no-op.
func (r *Result) StartWatch(ctx context.Context, log logger.Logger, cfg interface{}, onReload func()) {
	if r == nil || r.manager == nil {
		return
	}

	if log == nil {
		log = logger.NewTestLogger()
	}

	watchCtx := ctx
	watcherID := ""
	if r.descriptor.Name != "" {
		watcherID = config.RegisterWatcher(config.WatcherRegistration{
			Service: r.descriptor.Name,
			Scope:   r.descriptor.Scope,
			KVKey:   r.descriptor.KVKey,
		})
		watchCtx = config.ContextWithWatcher(ctx, watcherID)
	}

	wrappedReload := onReload
	if watcherID != "" || onReload != nil {
		wrappedReload = func() {
			if watcherID != "" {
				config.MarkWatcherEvent(watcherID, nil)
			}
			if onReload != nil {
				onReload()
			}
		}
	}

	r.manager.StartWatch(watchCtx, r.descriptor.KVKey, cfg, log, wrappedReload)
}

// Manager returns the underlying KV manager (may be nil).
func (r *Result) Manager() *config.KVManager {
	if r == nil {
		return nil
	}

	return r.manager
}

// Service loads, overlays, seeds, and optionally watches configuration for a managed service.
func Service(ctx context.Context, desc config.ServiceDescriptor, cfg interface{}, opts ServiceOptions) (*Result, error) {
	if ctx == nil {
		return nil, errors.New("context cannot be nil")
	}
	if opts.ConfigPath == "" {
		return nil, errors.New("config path is required")
	}

	cfgLoader := config.NewConfig(opts.Logger)

	var kvMgr *config.KVManager
	if opts.Role != "" {
		kvMgr = config.NewKVManagerFromEnv(ctx, opts.Role)
	}

	if kvMgr != nil {
		kvMgr.SetupConfigLoader(cfgLoader)
		if err := kvMgr.LoadAndOverlay(ctx, cfgLoader, opts.ConfigPath, cfg); err != nil {
			return nil, err
		}
		if err := kvMgr.BootstrapConfig(ctx, desc.KVKey, opts.ConfigPath, cfg); err != nil {
			return nil, err
		}
	} else {
		if err := cfgLoader.LoadAndValidate(ctx, opts.ConfigPath, cfg); err != nil {
			return nil, err
		}
	}

	result := &Result{
		manager:    kvMgr,
		descriptor: desc,
	}

	if !opts.DisableWatch && kvMgr != nil {
		log := opts.Logger
		if log == nil {
			log = logger.NewTestLogger()
		}
		result.StartWatch(ctx, log, cfg, opts.OnReload)
	}

	return result, nil
}
