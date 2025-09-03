package config

import (
	"context"

	cfgkv "github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/logger"
)

// StartKVWatchLog watches a KV key and logs when it changes.
// It owns the kvStore lifecycle: it will Close() it when ctx is done.
func StartKVWatchLog(ctx context.Context, kvStore cfgkv.KVStore, key string, log logger.Logger) {
	if kvStore == nil || key == "" {
		return
	}
	go func() {
		defer func() { _ = kvStore.Close() }()

		ch, err := kvStore.Watch(ctx, key)
		if err != nil {
			if log != nil {
				log.Warn().Err(err).Str("key", key).Msg("KV watch failed")
			}
			return
		}

		for {
			select {
			case <-ctx.Done():
				return
			case _, ok := <-ch:
				if !ok {
					return
				}

				if log != nil {
					log.Info().Str("key", key).Msg("KV config updated (restart or reload may be required)")
				}
			}
		}
	}()
}

// StartKVWatchOverlay watches a KV key and overlays JSON config bytes onto dst when updates arrive.
// If onChange is not nil, it is invoked after a successful merge.
// It also attempts an initial merge with the current KV value if present.
func StartKVWatchOverlay(ctx context.Context, kvStore cfgkv.KVStore, key string, dst interface{}, log logger.Logger, onChange func()) {
	if kvStore == nil || key == "" || dst == nil {
		return
	}
	go func() {
		defer func() { _ = kvStore.Close() }()

		if data, found, err := kvStore.Get(ctx, key); err == nil && found && len(data) > 0 {
			if err := MergeOverlayBytes(dst, data); err != nil {
				if log != nil {
					log.Warn().Err(err).Str("key", key).Msg("Failed initial KV overlay")
				}
			} else if onChange != nil {
				onChange()
			}
		}

		ch, err := kvStore.Watch(ctx, key)
		if err != nil {
			if log != nil {
				log.Warn().Err(err).Str("key", key).Msg("KV watch failed")
			}
			return
		}

		for {
			select {
			case <-ctx.Done():
				return
			case data, ok := <-ch:
				if !ok {
					return
				}

				if len(data) == 0 {
					if log != nil {
						log.Info().Str("key", key).Msg("KV delete or empty update")
					}
					continue
				}

				if err := MergeOverlayBytes(dst, data); err != nil {
					if log != nil {
						log.Warn().Err(err).Str("key", key).Msg("Failed KV overlay on update")
					}
				} else {
					if log != nil {
						log.Info().Str("key", key).Msg("Applied KV config overlay")
					}
					if onChange != nil {
						onChange()
					}
				}
			}
		}
	}()
}
