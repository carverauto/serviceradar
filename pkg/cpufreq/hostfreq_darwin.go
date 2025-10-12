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
	"time"
)

type hostfreqCore struct {
	Name   string  `json:"name"`
	AvgMHz float64 `json:"avg_mhz"`
}

type hostfreqPayload struct {
	Cores []hostfreqCore `json:"cores"`
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
		Cores: make([]CoreFrequency, 0, len(payload.Cores)),
	}

	for idx, core := range payload.Cores {
		hz := core.AvgMHz * 1_000_000
		if hz < 0 {
			hz = 0
		}

		snapshot.Cores = append(snapshot.Cores, CoreFrequency{
			CoreID:      idx,
			FrequencyHz: hz,
			Source:      FrequencySourceHostfreq,
		})
	}

	return snapshot, nil
}
