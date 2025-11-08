package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/config/kvgrpc"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errKVKeyEmpty           = errors.New("kv key is empty and no template specified")
	errKVWatchChannelClosed = errors.New("kv watch channel closed")
)

type options struct {
	service      string
	kvKey        string
	output       string
	templatePath string
	seed         bool
	watch        bool
	role         models.ServiceRole
}

func main() {
	opts := parseFlags()
	templateBytes, err := readTemplate(opts.templatePath)
	if err != nil {
		log.Fatalf("failed to read template: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	client, err := newKVClient(ctx, opts.role)
	if err != nil {
		cancel()
		log.Fatalf("failed to create KV client: %v", err) //nolint:gocritic // cancel is explicitly called before Fatalf
	}
	if client == nil && len(templateBytes) == 0 {
		log.Fatal("KV not configured and no template provided")
	}
	defer func() {
		if client != nil {
			_ = client.Close()
		}
	}()

	if err := syncOnce(ctx, client, opts, templateBytes); err != nil {
		log.Fatalf("sync failed: %v", err)
	}

	if opts.watch && client != nil {
		if err := watchLoop(ctx, client, opts); err != nil && !errors.Is(err, context.Canceled) {
			log.Fatalf("watch loop failed: %v", err)
		}
	}
}

func parseFlags() options {
	var (
		service      = flag.String("service", "", "Service descriptor name (e.g., flowgger)")
		kvKey        = flag.String("kv-key", "", "Override KV key (default derived from service)")
		output       = flag.String("output", "", "Path to write the rendered configuration")
		templatePath = flag.String("template", "", "Optional template file to seed from when KV is empty")
		seed         = flag.Bool("seed", true, "Write template contents to KV when the key is missing")
		watch        = flag.Bool("watch", false, "Stay running and watch the KV key for changes")
		role         = flag.String("role", string(models.RoleCore), "Service role for KV authentication (core, agent, poller, checker)")
	)
	flag.Parse()

	if *service == "" && *kvKey == "" {
		log.Fatal("either --service or --kv-key must be provided")
	}
	if *output == "" {
		log.Fatal("--output is required")
	}

	opts := options{
		service:      *service,
		kvKey:        *kvKey,
		output:       *output,
		templatePath: *templatePath,
		seed:         *seed,
		watch:        *watch,
		role:         models.ServiceRole(*role),
	}

	if opts.kvKey == "" && opts.service != "" {
		if desc, ok := config.ServiceDescriptorFor(opts.service); ok {
			opts.kvKey = desc.KVKey
		}
	}
	if opts.kvKey == "" {
		log.Fatal("unable to determine KV key; provide --kv-key explicitly")
	}

	return opts
}

func readTemplate(path string) ([]byte, error) {
	if path == "" {
		return nil, nil
	}
	return os.ReadFile(path)
}

func newKVClient(ctx context.Context, role models.ServiceRole) (*kvgrpc.Client, error) {
	client, closer, err := config.NewKVServiceClientFromEnv(ctx, role)
	if err != nil {
		return nil, err
	}
	if client == nil {
		return nil, nil
	}
	return kvgrpc.New(client, closer), nil
}

func syncOnce(ctx context.Context, client *kvgrpc.Client, opts options, template []byte) error {
	data, err := fetchConfig(ctx, client, opts.kvKey)
	if err != nil {
		return err
	}

	if len(data) == 0 {
		if len(template) == 0 {
			return fmt.Errorf("%w: %q", errKVKeyEmpty, opts.kvKey)
		}
		data = template
		if client != nil && opts.seed {
			if err := client.Put(ctx, opts.kvKey, template, 0); err != nil {
				return fmt.Errorf("failed to seed KV key %q: %w", opts.kvKey, err)
			}
			log.Printf("seeded KV key %s with template", opts.kvKey)
		}
	}

	if err := writeOutput(opts.output, data); err != nil {
		return fmt.Errorf("failed to write %s: %w", opts.output, err)
	}

	log.Printf("wrote %d bytes to %s", len(data), opts.output)
	return nil
}

func fetchConfig(ctx context.Context, client *kvgrpc.Client, key string) ([]byte, error) {
	if client == nil {
		return nil, nil
	}

	data, found, err := client.Get(ctx, key)
	if err != nil {
		return nil, fmt.Errorf("kv get %q failed: %w", key, err)
	}
	if !found {
		return nil, nil
	}
	return data, nil
}

func writeOutput(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func watchLoop(ctx context.Context, client *kvgrpc.Client, opts options) error {
	ch, err := client.Watch(ctx, opts.kvKey)
	if err != nil {
		return fmt.Errorf("kv watch %q failed: %w", opts.kvKey, err)
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case data, ok := <-ch:
			if !ok {
				return errKVWatchChannelClosed
			}
			if len(strings.TrimSpace(string(data))) == 0 {
				continue
			}
			if err := writeOutput(opts.output, data); err != nil {
				log.Printf("failed to update %s from KV: %v", opts.output, err)
				continue
			}
			log.Printf("updated %s from KV change (%d bytes)", opts.output, len(data))
		}
	}
}
