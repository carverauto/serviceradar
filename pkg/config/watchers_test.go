package config

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestWatcherRegistryTracksEvents(t *testing.T) {
	resetWatchersForTest()

	id := RegisterWatcher(WatcherRegistration{
		Service: "core",
		Scope:   ConfigScopeGlobal,
		KVKey:   "config/core.json",
	})
	require.NotEmpty(t, id)

	list := ListWatchers()
	require.Len(t, list, 1)
	require.Equal(t, "core", list[0].Service)
	require.Equal(t, WatcherStatusRunning, list[0].Status)

	MarkWatcherEvent(id, nil)
	list = ListWatchers()
	require.False(t, list[0].LastEvent.IsZero())

	MarkWatcherEvent(id, errors.New("overlay failed"))
	list = ListWatchers()
	require.Equal(t, WatcherStatusError, list[0].Status)
	require.Contains(t, list[0].LastError, "overlay failed")

	MarkWatcherStopped(id, context.DeadlineExceeded)
	list = ListWatchers()
	require.Equal(t, WatcherStatusStopped, list[0].Status)
	require.Contains(t, list[0].LastError, context.DeadlineExceeded.Error())
}

func TestContextWithWatcher(t *testing.T) {
	resetWatchersForTest()

	id := RegisterWatcher(WatcherRegistration{
		Service: "core",
		Scope:   ConfigScopeGlobal,
		KVKey:   "config/core.json",
	})
	ctx := ContextWithWatcher(context.Background(), id)
	require.NotNil(t, ctx)

	// Ensure watcher ID is preserved through derived contexts
	ctx, cancel := context.WithTimeout(ctx, time.Millisecond)
	defer cancel()

	require.Equal(t, id, watcherIDFromContext(ctx))
}
