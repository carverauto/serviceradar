package config

import (
	"context"
	"sync"
	"time"

	"github.com/google/uuid"
)

// WatcherStatus captures the current state for a KV watcher.
type WatcherStatus string

const (
	WatcherStatusRunning WatcherStatus = "running"
	WatcherStatusStopped WatcherStatus = "stopped"
	WatcherStatusError   WatcherStatus = "error"
)

// WatcherRegistration describes metadata recorded for a KV watcher.
type WatcherRegistration struct {
	Service string
	Scope   ConfigScope
	KVKey   string
}

// WatcherInfo exposes runtime metadata for an active watcher.
type WatcherInfo struct {
	ID        string        `json:"id"`
	Service   string        `json:"service"`
	Scope     ConfigScope   `json:"scope"`
	KVKey     string        `json:"kv_key"`
	StartedAt time.Time     `json:"started_at"`
	LastEvent time.Time     `json:"last_event,omitempty"`
	Status    WatcherStatus `json:"status"`
	LastError string        `json:"last_error,omitempty"`
}

var (
	watcherMu   sync.RWMutex
	watchers    = make(map[string]*WatcherInfo)
	watcherCtxK = struct{}{}
)

// RegisterWatcher records watcher metadata and returns a watcher ID.
func RegisterWatcher(reg WatcherRegistration) string {
	id := uuid.NewString()
	watcherMu.Lock()
	watchers[id] = &WatcherInfo{
		ID:        id,
		Service:   reg.Service,
		Scope:     reg.Scope,
		KVKey:     reg.KVKey,
		StartedAt: time.Now().UTC(),
		Status:    WatcherStatusRunning,
	}
	watcherMu.Unlock()
	return id
}

// ContextWithWatcher annotates a context with the watcher ID.
func ContextWithWatcher(ctx context.Context, watcherID string) context.Context {
	return withWatcherContext(ctx, watcherID)
}

// MarkWatcherEvent updates the last event timestamp for a watcher.
func MarkWatcherEvent(id string, err error) {
	if id == "" {
		return
	}
	watcherMu.Lock()
	defer watcherMu.Unlock()
	info, ok := watchers[id]
	if !ok {
		return
	}
	info.LastEvent = time.Now().UTC()
	if err != nil {
		info.Status = WatcherStatusError
		info.LastError = err.Error()
	} else {
		info.Status = WatcherStatusRunning
		info.LastError = ""
	}
}

// MarkWatcherStopped marks the watcher as stopped and records the last error if present.
func MarkWatcherStopped(id string, err error) {
	if id == "" {
		return
	}
	watcherMu.Lock()
	defer watcherMu.Unlock()
	info, ok := watchers[id]
	if !ok {
		return
	}
	info.Status = WatcherStatusStopped
	if err != nil && err != context.Canceled {
		info.LastError = err.Error()
	}
	if info.LastEvent.IsZero() {
		info.LastEvent = time.Now().UTC()
	}
}

// ListWatchers returns a snapshot of registered watchers.
func ListWatchers() []WatcherInfo {
	watcherMu.RLock()
	defer watcherMu.RUnlock()
	result := make([]WatcherInfo, 0, len(watchers))
	for _, info := range watchers {
		cloned := *info
		result = append(result, cloned)
	}
	return result
}

// withWatcherContext stores the watcher ID in the context chain.
func withWatcherContext(ctx context.Context, watcherID string) context.Context {
	if ctx == nil || watcherID == "" {
		return ctx
	}
	return context.WithValue(ctx, watcherCtxK, watcherID)
}

// watcherIDFromContext extracts the watcher ID from the context.
func watcherIDFromContext(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	if v := ctx.Value(watcherCtxK); v != nil {
		if id, ok := v.(string); ok {
			return id
		}
	}
	return ""
}

// resetWatchersForTest clears the watcher registry. Intended for tests only.
func resetWatchersForTest() {
	watcherMu.Lock()
	defer watcherMu.Unlock()
	watchers = make(map[string]*WatcherInfo)
}

// ResetWatchersForTest exposes a safe way for other packages to clear watcher state in tests.
func ResetWatchersForTest() {
	resetWatchersForTest()
}
