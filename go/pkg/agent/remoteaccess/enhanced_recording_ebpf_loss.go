/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package remoteaccess

import (
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/ebpf/probes"
)

const (
	enhancedBPFLossKernelDrops     = "kernel_drops"
	enhancedBPFLossParserFailures  = "parser_failures"
	enhancedBPFLossBackpressure    = "backpressure_drops"
	enhancedBPFLossEventFamily     = "event_family"
	enhancedBPFLossBackpressureMax = "backpressure_high_watermark"
)

type bpfLossTracker struct {
	now                 func() time.Time
	kernelDrops         map[string]uint64
	parserFailures      map[string]uint64
	backpressureDrops   map[string]uint64
	backpressureHighMax map[string]int
}

func newBPFLossTracker(now func() time.Time) *bpfLossTracker {
	if now == nil {
		now = time.Now
	}

	return &bpfLossTracker{
		now:                 now,
		kernelDrops:         make(map[string]uint64),
		parserFailures:      make(map[string]uint64),
		backpressureDrops:   make(map[string]uint64),
		backpressureHighMax: make(map[string]int),
	}
}

func (tracker *bpfLossTracker) addKernelCounters(eventFamily string, counters probes.LossCounters) {
	if tracker == nil || eventFamily == "" {
		return
	}
	if counters.KernelDrops > 0 {
		tracker.kernelDrops[eventFamily] += counters.KernelDrops
	}
	if counters.ParserFailures > 0 {
		tracker.parserFailures[eventFamily] += counters.ParserFailures
	}
}

func (tracker *bpfLossTracker) addParserFailure(eventFamily string) {
	if tracker == nil || eventFamily == "" {
		return
	}
	tracker.parserFailures[eventFamily]++
}

func (tracker *bpfLossTracker) emitOrCountBackpressure(events chan<- EnhancedEvent, event EnhancedEvent) {
	if tracker == nil {
		select {
		case events <- event:
		default:
		}

		return
	}

	tracker.emitLossEvents(events)

	select {
	case events <- event:
	default:
		tracker.backpressureDrops[event.EventType]++
		tracker.emitLossEvents(events)
	}
}

func (tracker *bpfLossTracker) noteRingRemaining(eventFamily string, remaining int) {
	if tracker == nil || eventFamily == "" || remaining <= 0 {
		return
	}
	if remaining > tracker.backpressureHighMax[eventFamily] {
		tracker.backpressureHighMax[eventFamily] = remaining
	}
}

func (tracker *bpfLossTracker) drainLossEvents() []EnhancedEvent {
	if tracker == nil {
		return nil
	}

	events := tracker.lossEvents()
	for _, event := range events {
		tracker.resetLossFamily(event.Metadata[enhancedBPFLossEventFamily])
	}

	return events
}

func (tracker *bpfLossTracker) emitLossEvents(events chan<- EnhancedEvent) int {
	if tracker == nil {
		return 0
	}

	sent := 0
	for _, event := range tracker.lossEvents() {
		select {
		case events <- event:
			tracker.resetLossFamily(event.Metadata[enhancedBPFLossEventFamily])
			sent++
		default:
			return sent
		}
	}

	return sent
}

func (tracker *bpfLossTracker) lossEvents() []EnhancedEvent {
	families := make(map[string]struct{})
	for family := range tracker.kernelDrops {
		families[family] = struct{}{}
	}
	for family := range tracker.parserFailures {
		families[family] = struct{}{}
	}
	for family := range tracker.backpressureDrops {
		families[family] = struct{}{}
	}
	for family := range tracker.backpressureHighMax {
		families[family] = struct{}{}
	}

	events := make([]EnhancedEvent, 0, len(families))
	for family := range families {
		kernelDrops := tracker.kernelDrops[family]
		parserFailures := tracker.parserFailures[family]
		backpressureDrops := tracker.backpressureDrops[family]
		backpressureHighMax := tracker.backpressureHighMax[family]
		totalDrops := kernelDrops + parserFailures + backpressureDrops

		if totalDrops == 0 && backpressureHighMax == 0 {
			continue
		}

		metadata := map[string]string{
			"source":                       enhancedSourceLinuxEBPF,
			"bpf":                          enhancedMetadataTrue,
			"collector":                    enhancedBPFCollectorName,
			enhancedBPFLossEventFamily:     family,
			enhancedBPFLossKernelDrops:     strconv.FormatUint(kernelDrops, 10),
			enhancedBPFLossParserFailures:  strconv.FormatUint(parserFailures, 10),
			enhancedBPFLossBackpressure:    strconv.FormatUint(backpressureDrops, 10),
			enhancedBPFLossBackpressureMax: strconv.Itoa(backpressureHighMax),
		}
		events = append(events, EnhancedEvent{
			EventType:         EnhancedEventLoss,
			TimestampUnixNano: tracker.now().UnixNano(),
			DroppedEvents:     totalDrops,
			Metadata:          metadata,
		})
	}

	return events
}

func (tracker *bpfLossTracker) resetLossFamily(family string) {
	delete(tracker.kernelDrops, family)
	delete(tracker.parserFailures, family)
	delete(tracker.backpressureDrops, family)
	delete(tracker.backpressureHighMax, family)
}
