//go:build darwin

package cpufreq

/*
#cgo darwin CFLAGS: -fobjc-arc
#cgo darwin CXXFLAGS: -std=c++20 -fobjc-arc -x objective-c++
#cgo darwin LDFLAGS: -framework Foundation -framework IOKit -framework CoreFoundation -lIOReport
#include "hostfreq_bridge.h"
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"sync"
	"time"
	"unicode"
)

type hostfreqCore struct {
	Name   string  `json:"name"`
	AvgMHz float64 `json:"avg_mhz"`
}

type hostfreqCluster struct {
	Name   string  `json:"name"`
	AvgMHz float64 `json:"avg_mhz"`
}

type hostfreqPayload struct {
	Cores     []hostfreqCore    `json:"cores"`
	Clusters  []hostfreqCluster `json:"clusters"`
	Timestamp string            `json:"timestamp"`
}

const (
	hostfreqStatusOK          = 0
	hostfreqStatusUnavailable = 1
	hostfreqStatusPermission  = 2
	hostfreqStatusInternal    = 3

	hostfreqMinInterval = 1 * time.Second
	hostfreqCacheTTL    = 2 * time.Second
)

var (
	errHostfreqPermission   = errors.New("hostfreq permission error")
	errHostfreqInternal     = errors.New("hostfreq internal error")
	errHostfreqNoData       = errors.New("hostfreq returned no data")
	errHostfreqEmptyPayload = errors.New("hostfreq returned empty payload")
)

var hostfreqCache struct {
	mu       sync.Mutex
	snapshot *Snapshot
	fetched  time.Time
}

func collectViaHostfreq(ctx context.Context, window time.Duration) (*Snapshot, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	if snap := hostfreqCacheSnapshot(); snap != nil {
		return snap, nil
	}

	interval := int(window / time.Millisecond)
	if interval <= 0 {
		interval = int(defaultSampleWindow / time.Millisecond)
	}
	if min := int(hostfreqMinInterval / time.Millisecond); interval < min {
		interval = min
	}

	var outJSON *C.char
	var outError *C.char
	var actual C.double

	const smoothingEnabled = 1
	//nolint:gocritic // false positive when analyzing CGO bridge macro.
	status := int(C.hostfreq_collect_json(
		C.int(interval),
		C.int(smoothingEnabled),
		&outJSON,
		&actual,
		&outError,
	))
	defer C.hostfreq_free(outJSON)
	defer C.hostfreq_free(outError)

	if status != hostfreqStatusOK {
		message := ""
		if outError != nil {
			message = C.GoString(outError)
		}
		if message == "" {
			message = C.GoString(C.hostfreq_status_string(C.int(status)))
		}

		switch status {
		case hostfreqStatusUnavailable:
			if message != "" {
				return nil, fmt.Errorf("%w: %s", ErrFrequencyUnavailable, message)
			}
			return nil, ErrFrequencyUnavailable
		case hostfreqStatusPermission:
			return nil, fmt.Errorf("%w: %s", errHostfreqPermission, message)
		default:
			return nil, fmt.Errorf("%w: %s", errHostfreqInternal, message)
		}
	}

	if outJSON == nil {
		return nil, errHostfreqNoData
	}

	jsonStr := C.GoString(outJSON)
	if jsonStr == "" {
		return nil, errHostfreqEmptyPayload
	}

	var payload hostfreqPayload
	if err := json.Unmarshal([]byte(jsonStr), &payload); err != nil {
		return nil, fmt.Errorf("failed to parse hostfreq output: %w", err)
	}

	if len(payload.Cores) == 0 {
		return nil, ErrFrequencyUnavailable
	}

	snapshot, err := payloadToSnapshot(payload)
	if err != nil {
		return nil, err
	}

	hostfreqCacheStore(snapshot)

	return hostfreqCacheSnapshot(), nil
}

func payloadToSnapshot(payload hostfreqPayload) (*Snapshot, error) {
	if len(payload.Cores) == 0 {
		return nil, ErrFrequencyUnavailable
	}

	snapshot := &Snapshot{
		Cores:    make([]CoreFrequency, 0, len(payload.Cores)),
		Clusters: make([]ClusterFrequency, 0, len(payload.Clusters)),
	}

	hasFrequency := false

	for idx, core := range payload.Cores {
		if math.IsNaN(core.AvgMHz) || math.IsInf(core.AvgMHz, 0) {
			continue
		}

		hz := core.AvgMHz * 1_000_000
		if hz < 0 {
			hz = 0
		}

		if hz > 0 {
			hasFrequency = true
		}

		label := core.Name
		cluster := clusterFromLabel(label)

		snapshot.Cores = append(snapshot.Cores, CoreFrequency{
			CoreID:      idx,
			Label:       label,
			Cluster:     cluster,
			FrequencyHz: hz,
			Source:      FrequencySourceHostfreq,
		})
	}

	for _, cluster := range payload.Clusters {
		if math.IsNaN(cluster.AvgMHz) || math.IsInf(cluster.AvgMHz, 0) {
			continue
		}

		hz := cluster.AvgMHz * 1_000_000
		if hz < 0 {
			hz = 0
		}

		if hz > 0 {
			hasFrequency = true
		}

		snapshot.Clusters = append(snapshot.Clusters, ClusterFrequency{
			Name:        cluster.Name,
			FrequencyHz: hz,
			Source:      FrequencySourceHostfreq,
		})
	}

	if !hasFrequency {
		return nil, ErrFrequencyUnavailable
	}

	return snapshot, nil
}

func clusterFromLabel(label string) string {
	label = strings.TrimSpace(label)
	if label == "" {
		return ""
	}
	trimmed := strings.TrimRightFunc(label, func(r rune) bool {
		return unicode.IsDigit(r)
	})
	if trimmed == "" {
		return ""
	}
	return trimmed
}

func hostfreqCacheSnapshot() *Snapshot {
	hostfreqCache.mu.Lock()
	defer hostfreqCache.mu.Unlock()

	if hostfreqCache.snapshot == nil {
		return nil
	}

	if time.Since(hostfreqCache.fetched) > hostfreqCacheTTL {
		return nil
	}

	return snapshotClone(hostfreqCache.snapshot)
}

func hostfreqCacheStore(snapshot *Snapshot) {
	hostfreqCache.mu.Lock()
	defer hostfreqCache.mu.Unlock()

	hostfreqCache.snapshot = snapshotClone(snapshot)
	hostfreqCache.fetched = time.Now()
}

func snapshotClone(src *Snapshot) *Snapshot {
	if src == nil {
		return nil
	}

	out := &Snapshot{
		Cores:    make([]CoreFrequency, len(src.Cores)),
		Clusters: make([]ClusterFrequency, len(src.Clusters)),
	}
	copy(out.Cores, src.Cores)
	copy(out.Clusters, src.Clusters)
	return out
}
