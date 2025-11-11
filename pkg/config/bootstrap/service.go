package bootstrap

import (
	"context"
	"errors"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errContextNil      = errors.New("context cannot be nil")
	errConfigPathEmpty = errors.New("config path is required")
)

const watcherSnapshotRefreshInterval = time.Minute

// ServiceOptions controls how a service configuration is loaded and watched.
type ServiceOptions struct {
	Role         models.ServiceRole
	ConfigPath   string
	Logger       logger.Logger
	OnReload     func()
	DisableWatch bool
	InstanceID   string
	KeyContext   config.KeyContext
	KeyContextFn func(cfg interface{}) config.KeyContext
}

// Result contains helpers returned from Service.
type Result struct {
	manager    *config.KVManager
	descriptor config.ServiceDescriptor
	instanceID string
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
			Service:    r.descriptor.Name,
			Scope:      r.descriptor.Scope,
			KVKey:      r.descriptor.KVKey,
			InstanceID: r.instanceIDOrDefault(),
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

// SetInstanceID overrides the identifier associated with watcher telemetry (defaults to descriptor name).
func (r *Result) SetInstanceID(id string) {
	if r == nil {
		return
	}
	r.instanceID = id
}

func (r *Result) instanceIDOrDefault() string {
	if r == nil {
		return ""
	}
	if r.instanceID != "" {
		return r.instanceID
	}
	if r.descriptor.Name != "" {
		return r.descriptor.Name
	}
	return "default"
}

// Service loads, overlays, seeds, and optionally watches configuration for a managed service.
func Service(ctx context.Context, desc config.ServiceDescriptor, cfg interface{}, opts ServiceOptions) (*Result, error) {
	if ctx == nil {
		return nil, errContextNil
	}
	if opts.ConfigPath == "" {
		return nil, errConfigPathEmpty
	}

	cfgLoader := config.NewConfig(opts.Logger)

	var kvMgr *config.KVManager
	if opts.Role != "" {
		var err error
		kvMgr, err = config.NewKVManagerFromEnv(ctx, opts.Role)
		if err != nil {
			waitLogger := opts.Logger
			if waitLogger == nil {
				waitLogger = logger.NewTestLogger()
			}
			kvMgr, err = config.NewKVManagerFromEnvWithRetry(ctx, opts.Role, waitLogger)
			if err != nil {
				return nil, err
			}
		}
	}
	if kvMgr != nil {
		kvMgr.SetupConfigLoader(cfgLoader)
	}

	if err := cfgLoader.LoadAndValidate(ctx, opts.ConfigPath, cfg); err != nil {
		return nil, err
	}

	keyCtx := mergeKeyContexts(opts.KeyContext, nil)
	if opts.KeyContextFn != nil {
		fnCtx := opts.KeyContextFn(cfg)
		keyCtx = mergeKeyContexts(keyCtx, &fnCtx)
	}

	resolvedKey, err := desc.ResolveKVKey(keyCtx)
	if err != nil {
		return nil, err
	}
	desc.KVKey = resolvedKey

	if kvMgr != nil {
		if err := kvMgr.OverlayConfig(ctx, desc.KVKey, cfg); err != nil && opts.Logger != nil {
			opts.Logger.Warn().
				Err(err).
				Str("service", desc.Name).
				Str("kv_key", desc.KVKey).
				Msg("failed to overlay configuration from KV")
		}
		if err := kvMgr.BootstrapConfig(ctx, desc.KVKey, opts.ConfigPath, cfg); err != nil {
			return nil, err
		}
		if err := kvMgr.RepairConfigPlaceholders(ctx, desc, opts.ConfigPath, cfg); err != nil && opts.Logger != nil {
			opts.Logger.Warn().
				Err(err).
				Str("service", desc.Name).
				Str("kv_key", desc.KVKey).
				Msg("failed to repair placeholder configuration; KV retains existing value")
		}
	}

	instanceID := opts.InstanceID
	if instanceID == "" {
		instanceID = desc.Name
	}

	result := &Result{
		manager:    kvMgr,
		descriptor: desc,
		instanceID: instanceID,
	}

	if kvMgr != nil {
		log := opts.Logger
		if log == nil {
			log = logger.NewTestLogger()
		}

		publishSnapshot := func(info config.WatcherInfo) {
			if info.InstanceID == "" {
				info.InstanceID = result.instanceIDOrDefault()
			}
			if err := kvMgr.PublishWatcherSnapshot(context.Background(), info); err != nil {
				log.Warn().
					Err(err).
					Str("service", info.Service).
					Str("kv_key", info.KVKey).
					Msg("failed to publish watcher snapshot")
			}
		}

		config.SetWatcherUpdateHook(publishSnapshot)

		if watcherSnapshotRefreshInterval > 0 {
			go func(ctx context.Context) {
				ticker := time.NewTicker(watcherSnapshotRefreshInterval)
				defer ticker.Stop()
				for {
					select {
					case <-ctx.Done():
						return
					case <-ticker.C:
						for _, info := range config.ListWatchers() {
							publishSnapshot(info)
						}
					}
				}
			}(ctx)
		}
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

func mergeKeyContexts(base config.KeyContext, override *config.KeyContext) config.KeyContext {
	if override == nil {
		return base
	}
	if override.AgentID != "" {
		base.AgentID = override.AgentID
	}
	if override.PollerID != "" {
		base.PollerID = override.PollerID
	}
	return base
}
