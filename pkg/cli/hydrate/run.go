package hydrate

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/config/kvgrpc"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	// DefaultBundlePath is where packaging installs the generated config bundle.
	DefaultBundlePath = "/usr/local/share/serviceradar/config-bundle.json"

	defaultKVTimeout = 5 * time.Second
)

// Options control how configuration hydration is executed.
type Options struct {
	BundlePath string
	Services   []string
	Force      bool
	Timeout    time.Duration
	Role       models.ServiceRole
}

// ResultAction describes the outcome for a KV entry.
type ResultAction string

const (
	// ActionCreated denotes a KV key that was absent and is now populated.
	ActionCreated ResultAction = "created"
	// ActionOverwritten denotes a KV key that existed but was replaced (force mode).
	ActionOverwritten ResultAction = "overwritten"
	// ActionSkipped denotes a KV key that already existed and was left untouched.
	ActionSkipped ResultAction = "skipped"
)

// Result captures the outcome for a single KV entry.
type Result struct {
	Component string
	KVKey     string
	Action    ResultAction
}

// Summary reports the overall hydration outcome.
type Summary struct {
	Source  string
	Results []Result
}

// Execute performs hydration of configuration defaults into the KV store.
func Execute(ctx context.Context, opts Options) (Summary, error) {
	if opts.Role == "" {
		opts.Role = models.RoleCore
	}

	bundle, source, err := loadBundle(opts.BundlePath)
	if err != nil {
		return Summary{}, err
	}

	components, err := bundle.FindComponents(opts.Services)
	if err != nil {
		return Summary{}, err
	}

	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = defaultKVTimeout
	}

	kvClient, closer, err := config.NewKVServiceClientFromEnv(ctx, opts.Role)
	if err != nil {
		return Summary{}, fmt.Errorf("failed to connect to KV: %w", err)
	}
	if kvClient == nil {
		return Summary{}, errors.New("KV environment not configured; set KV_ADDRESS and TLS credentials")
	}

	client := kvgrpc.New(kvClient, closer)
	defer func() { _ = client.Close() }()

	summary := Summary{Source: source}

	for _, comp := range components {
		for _, file := range comp.Files {
			action, err := upsertConfig(ctx, client, file, timeout, opts.Force)
			if err != nil {
				return summary, fmt.Errorf("%s (%s): %w", file.KVKey, comp.Name, err)
			}

			summary.Results = append(summary.Results, Result{
				Component: comp.Name,
				KVKey:     file.KVKey,
				Action:    action,
			})
		}
	}

	sort.Slice(summary.Results, func(i, j int) bool {
		if summary.Results[i].Component == summary.Results[j].Component {
			return summary.Results[i].KVKey < summary.Results[j].KVKey
		}

		return summary.Results[i].Component < summary.Results[j].Component
	})

	return summary, nil
}

func loadBundle(explicit string) (*Bundle, string, error) {
	if explicit != "" {
		path := filepath.Clean(explicit)
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, "", fmt.Errorf("reading bundle %s: %w", path, err)
		}

		b, err := Load(data)
		if err != nil {
			return nil, "", fmt.Errorf("parsing bundle %s: %w", path, err)
		}

		return b, path, nil
	}

	if data, err := os.ReadFile(DefaultBundlePath); err == nil {
		b, err := Load(data)
		if err != nil {
			return nil, "", fmt.Errorf("parsing bundle %s: %w", DefaultBundlePath, err)
		}

		return b, DefaultBundlePath, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, "", fmt.Errorf("reading bundle %s: %w", DefaultBundlePath, err)
	}

	b, err := Default()
	if err != nil {
		return nil, "", err
	}

	return b, "embedded bundle", nil
}

type kvWriter interface {
	Get(ctx context.Context, key string) ([]byte, bool, error)
	Put(ctx context.Context, key string, value []byte, ttl time.Duration) error
}

func upsertConfig(ctx context.Context, store kvWriter, file ConfigFile, timeout time.Duration, force bool) (ResultAction, error) {
	ctxGet, cancel := context.WithTimeout(ctx, timeout)
	_, found, err := store.Get(ctxGet, file.KVKey)
	cancel()
	if err != nil {
		return ActionSkipped, fmt.Errorf("fetching existing value: %w", err)
	}

	if found && !force {
		return ActionSkipped, nil
	}

	action := ActionCreated
	if found && force {
		action = ActionOverwritten
	}

	ctxPut, cancel := context.WithTimeout(ctx, timeout)
	err = store.Put(ctxPut, file.KVKey, file.Bytes(), 0)
	cancel()
	if err != nil {
		return ActionSkipped, fmt.Errorf("writing value: %w", err)
	}

	return action, nil
}
