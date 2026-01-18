package bootstrap

import (
	"context"
	"errors"
	"os"
	"strings"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errContextNil      = errors.New("context cannot be nil")
	errConfigPathEmpty = errors.New("config path is required")
)

// ServiceOptions controls how a service configuration is loaded.
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
	descriptor config.ServiceDescriptor
	instanceID string
}

// Close is a no-op now that KV-managed config is removed.
func (r *Result) Close() error {
	return nil
}

// StartWatch is a no-op now that KV-managed config is removed.
func (r *Result) StartWatch(_ context.Context, _ logger.Logger, _ interface{}, _ func()) {}

// SetInstanceID overrides the identifier associated with watcher telemetry (unused now).
func (r *Result) SetInstanceID(id string) {
	if r == nil {
		return
	}
	r.instanceID = id
}

func logMergedConfig(log logger.Logger, desc config.ServiceDescriptor, cfg interface{}) {
	if log == nil || cfg == nil {
		return
	}

	filtered, err := models.FilterSensitiveFields(cfg)
	if err != nil {
		log.Warn().
			Err(err).
			Str("service", desc.Name).
			Msg("failed to filter sensitive fields for config snapshot")
		return
	}

	log.Info().
		Str("service", desc.Name).
		Interface("config", filtered).
		Msg("loaded service configuration")
}

// Service loads configuration for a managed service (file + optional pinned overlay).
func Service(ctx context.Context, desc config.ServiceDescriptor, cfg interface{}, opts ServiceOptions) (*Result, error) {
	if ctx == nil {
		return nil, errContextNil
	}
	if opts.ConfigPath == "" {
		return nil, errConfigPathEmpty
	}

	cfgLoader := config.NewConfig(opts.Logger)
	pinnedPath := strings.TrimSpace(os.Getenv("PINNED_CONFIG_PATH"))

	if err := cfgLoader.LoadAndValidate(ctx, opts.ConfigPath, cfg); err != nil {
		return nil, err
	}

	// Apply pinned config last: pinned > default.
	if pinnedPath != "" {
		if err := cfgLoader.OverlayPinned(ctx, pinnedPath, cfg); err != nil {
			return nil, err
		}
	}

	log := opts.Logger
	if log == nil {
		log = logger.NewTestLogger()
	}
	logMergedConfig(log, desc, cfg)

	instanceID := opts.InstanceID
	if instanceID == "" {
		instanceID = desc.Name
	}

	result := &Result{
		descriptor: desc,
		instanceID: instanceID,
	}

	return result, nil
}
