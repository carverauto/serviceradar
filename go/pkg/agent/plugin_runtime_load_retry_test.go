package agent

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const loadRetryAssignmentID = "scheduled-load-retry-1"

func scheduledPluginConfig(downloadURL string, interval time.Duration) *proto.PluginConfig {
	return &proto.PluginConfig{
		Assignments: []*proto.PluginAssignmentConfig{
			{
				AssignmentId: loadRetryAssignmentID,
				PluginId:     "example-inventory",
				PackageId:    "pkg-load-retry-1",
				Entrypoint:   "run_check",
				Enabled:      true,
				IntervalSec:  int32(interval.Seconds()),
				TimeoutSec:   5,
				DownloadUrl:  downloadURL,
			},
		},
	}
}

// A scheduled run whose module cannot be downloaded must be retried before the
// next interval, so a long-interval plugin recovers once the artifact store
// serves the binary again instead of staying failed until its next run.
func TestPluginRunnerRetriesModuleLoadBeforeNextInterval(t *testing.T) {
	var available atomic.Bool
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if !available.Load() {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte("\x00asm"))
	}))
	defer server.Close()

	mgr := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:   logger.NewTestLogger(),
		CacheDir: t.TempDir(),
	})
	defer mgr.Stop()
	mgr.loadRetryBase = 20 * time.Millisecond
	mgr.loadRetryMax = 200 * time.Millisecond

	mgr.ApplyConfig(scheduledPluginConfig(server.URL+"/artifacts/plugins/pkg-load-retry-1/blob/download", time.Hour))

	// The first scheduled run and the config-apply prefetch both hit the
	// missing artifact. Only a retry can fetch it after it becomes available.
	waitFor(t, 5*time.Second, func() bool { return requests.Load() >= 2 })
	available.Store(true)

	waitFor(t, 5*time.Second, func() bool {
		mgr.stateMu.Lock()
		defer mgr.stateMu.Unlock()
		state := mgr.states[loadRetryAssignmentID]
		return state != nil && state.load.status == pluginLoadStatusLoaded
	})
}

// A retry that cannot get an execution slot never attempted the load, so it
// must keep the retry chain alive rather than fall back to the full interval.
func TestPluginRunnerKeepsLoadRetryAliveWhenRetryIsNotAdmitted(t *testing.T) {
	var available atomic.Bool
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if !available.Load() {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte("\x00asm"))
	}))
	defer server.Close()

	mgr := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:   logger.NewTestLogger(),
		CacheDir: t.TempDir(),
	})
	defer mgr.Stop()
	mgr.loadRetryBase = 20 * time.Millisecond
	mgr.loadRetryMax = 40 * time.Millisecond

	mgr.ApplyConfig(scheduledPluginConfig(server.URL+"/artifacts/plugins/pkg-load-retry-1/blob/download", time.Hour))
	waitFor(t, 5*time.Second, func() bool { return requests.Load() >= 2 })

	mgr.setLimits(pluginEngineLimits{MaxConcurrent: 1})
	waitFor(t, 5*time.Second, mgr.acquireSlot)
	available.Store(true)

	waitFor(t, 5*time.Second, func() bool {
		for _, result := range mgr.DrainResults(64) {
			if bytes.Contains(result.Payload, []byte("admission denied")) {
				return true
			}
		}
		return false
	})
	mgr.releaseSlot()

	waitFor(t, 5*time.Second, func() bool {
		mgr.stateMu.Lock()
		defer mgr.stateMu.Unlock()
		state := mgr.states[loadRetryAssignmentID]
		return state != nil && state.load.status == pluginLoadStatusLoaded
	})
}

func TestPluginLoadRetryBackoffDoublesAndStopsAtInterval(t *testing.T) {
	daily := pluginLoadRetryBackoff{base: time.Minute, max: 15 * time.Minute, interval: 24 * time.Hour}
	want := []time.Duration{
		time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 15 * time.Minute, 15 * time.Minute,
	}
	for i, expected := range want {
		got, ok := daily.next()
		if !ok || got != expected {
			t.Fatalf("retry %d = (%s, %v), want (%s, true)", i, got, ok, expected)
		}
	}

	daily.reset()
	if got, ok := daily.next(); !ok || got != time.Minute {
		t.Fatalf("after reset = (%s, %v), want (1m, true)", got, ok)
	}

	short := pluginLoadRetryBackoff{base: time.Minute, max: 15 * time.Minute, interval: 5 * time.Minute}
	for i, expected := range []time.Duration{time.Minute, 2 * time.Minute, 4 * time.Minute} {
		if got, ok := short.next(); !ok || got != expected {
			t.Fatalf("short retry %d = (%s, %v), want (%s, true)", i, got, ok, expected)
		}
	}
	if got, ok := short.next(); ok {
		t.Fatalf("retry at or past the interval should defer to the ticker, got %s", got)
	}

	everyMinute := pluginLoadRetryBackoff{base: time.Minute, max: 15 * time.Minute, interval: time.Minute}
	if got, ok := everyMinute.next(); ok {
		t.Fatalf("interval no longer than the base delay should not retry, got %s", got)
	}
}
