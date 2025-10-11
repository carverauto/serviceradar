//go:build darwin

package cpufreq

/*
#cgo darwin CFLAGS: -fobjc-arc -I${SRCDIR}
#cgo darwin CXXFLAGS: -std=c++20 -x objective-c++ -fobjc-arc -I${SRCDIR}
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

	status := C.hostfreq_collect_json(C.int(interval), C.int(1), &outJSON, &actual, &outError)
	defer C.hostfreq_free(outJSON)
	defer C.hostfreq_free(outError)

	if int(status) != hostfreqStatusOK {
		message := ""
		if outError != nil {
			message = C.GoString(outError)
		}
		if message == "" {
			message = C.GoString(C.hostfreq_status_string(status))
		}

		switch int(status) {
		case hostfreqStatusUnavailable:
			if message != "" {
				return nil, fmt.Errorf("%w: %s", ErrFrequencyUnavailable, message)
			}
			return nil, ErrFrequencyUnavailable
		case hostfreqStatusPermission:
			return nil, fmt.Errorf("hostfreq permission error: %s", message)
		default:
			return nil, fmt.Errorf("hostfreq internal error: %s", message)
		}
	}

	if outJSON == nil {
		return nil, errors.New("hostfreq returned no data")
	}

	jsonStr := C.GoString(outJSON)
	if jsonStr == "" {
		return nil, errors.New("hostfreq returned empty payload")
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
