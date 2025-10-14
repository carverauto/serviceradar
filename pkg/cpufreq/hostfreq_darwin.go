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
	"strings"
	"time"
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
	Cores    []hostfreqCore    `json:"cores"`
	Clusters []hostfreqCluster `json:"clusters"`
}

const (
	hostfreqStatusOK          = 0
	hostfreqStatusUnavailable = 1
	hostfreqStatusPermission  = 2
	hostfreqStatusInternal    = 3
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

	snapshot := &Snapshot{
		Cores:    make([]CoreFrequency, 0, len(payload.Cores)),
		Clusters: make([]ClusterFrequency, 0, len(payload.Clusters)),
	}

	for idx, core := range payload.Cores {
		hz := core.AvgMHz * 1_000_000
		if hz < 0 {
			hz = 0
		}

		label := core.Name
		cluster := deriveClusterFromLabel(label)
		snapshot.Cores = append(snapshot.Cores, CoreFrequency{
			CoreID:      idx,
			FrequencyHz: hz,
			Label:       label,
			Cluster:     cluster,
			Source:      FrequencySourceHostfreq,
		})
	}

	for _, cluster := range payload.Clusters {
		hz := cluster.AvgMHz * 1_000_000
		if hz < 0 {
			hz = 0
		}

		name := cluster.Name
		if name == "" {
			continue
		}

		snapshot.Clusters = append(snapshot.Clusters, ClusterFrequency{
			Name:        strings.ToUpper(name),
			FrequencyHz: hz,
		})
	}

	return snapshot, nil
}

func deriveClusterFromLabel(label string) string {
	label = strings.TrimSpace(label)
	if label == "" {
		return ""
	}

	for idx := 0; idx < len(label); idx++ {
		if label[idx] >= '0' && label[idx] <= '9' {
			if idx == 0 {
				return strings.ToUpper(label)
			}
			return strings.ToUpper(label[:idx])
		}
	}

	return strings.ToUpper(label)
}
