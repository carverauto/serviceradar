package config

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// WatcherSnapshot is the serialized representation stored in KV.
type WatcherSnapshot struct {
	WatcherInfo
	UpdatedAt time.Time `json:"updated_at"`
}

// WatcherSnapshotTTL is the freshness window used by the admin APIs to treat
// watcher snapshots as "alive".
const WatcherSnapshotTTL = 5 * time.Minute

var errWatcherServiceRequired = errors.New("service is required for watcher snapshot")

// WatcherSnapshotKey returns the canonical KV key for a watcher record.
func WatcherSnapshotKey(service, instanceID string) (string, error) {
	if service == "" {
		return "", errWatcherServiceRequired
	}
	if instanceID == "" {
		instanceID = service
	}
	return fmt.Sprintf("watchers/%s/%s.json", service, instanceID), nil
}

// PublishWatcherSnapshot stores watcher metadata in KV so that remote processes can read it.
func (m *KVManager) PublishWatcherSnapshot(ctx context.Context, info WatcherInfo) error {
	if m == nil || m.client == nil {
		return errKVClientUnavailable
	}
	key, err := WatcherSnapshotKey(info.Service, info.InstanceID)
	if err != nil {
		return err
	}

	payload, err := json.Marshal(WatcherSnapshot{
		WatcherInfo: info,
		UpdatedAt:   time.Now().UTC(),
	})
	if err != nil {
		return err
	}

	// Do not rely on per-entry TTL support in the KV backend. Instead, embed an
	// UpdatedAt timestamp and let readers treat stale snapshots as offline.
	return m.client.Put(ctx, key, payload, 0)
}
