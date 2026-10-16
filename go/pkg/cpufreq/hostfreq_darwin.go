//go:build darwin

package cpufreq

/*
#cgo darwin CFLAGS: -fobjc-arc
#cgo darwin CXXFLAGS: -std=c++20 -fobjc-arc -x objective-c++
#cgo darwin LDFLAGS: -framework Foundation -framework IOKit -framework CoreFoundation -lIOReport
#include "hostfreq_bridge.h"

// hostfreq_result carries hostfreq_collect_json's out-parameters back by value,
// so the Go caller passes the bridge no Go pointers.
typedef struct {
	int status;
	char* json;
	double actual_interval_ms;
	char* error;
} hostfreq_result;

static hostfreq_result hostfreq_collect(int interval_ms, int sample_count) {
	hostfreq_result result = {0};
	result.status = hostfreq_collect_json(interval_ms, sample_count, &result.json,
	                                      &result.actual_interval_ms, &result.error);
	return result;
}
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
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

	hostfreqMinInterval = 250 * time.Millisecond
)

var (
	errHostfreqPermission   = errors.New("hostfreq permission error")
	errHostfreqInternal     = errors.New("hostfreq internal error")
	errHostfreqNoData       = errors.New("hostfreq returned no data")
	errHostfreqEmptyPayload = errors.New("hostfreq returned empty payload")
)

func collectViaHostfreq(ctx context.Context, window time.Duration) (*Snapshot, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	interval := int(window / time.Millisecond)
	if interval <= 0 {
		interval = int(defaultSampleWindow / time.Millisecond)
	}
	if min := int(hostfreqMinInterval / time.Millisecond); interval < min {
		interval = min
	}

	const smoothingEnabled = 1
	result := C.hostfreq_collect(C.int(interval), C.int(smoothingEnabled))
	defer C.hostfreq_free(result.json)
	defer C.hostfreq_free(result.error)

	status := int(result.status)
	outJSON, outError := result.json, result.error

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
	trimmed := strings.TrimRightFunc(label, unicode.IsDigit)
	if trimmed == "" {
		return ""
	}
	return trimmed
}
