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

package probes

import (
	"errors"
	"fmt"

	"github.com/cilium/ebpf"
)

const (
	LossCounterKernelDrops uint32 = iota
	LossCounterParserFailures
	LossCounterCount

	CommandLossesMap = "sr_command_losses"
	FileLossesMap    = "sr_file_losses"
	NetworkLossesMap = "sr_network_losses"
)

var (
	ErrReadLossCountersNilMap  = errors.New("read loss counters: nil map")
	ErrResetLossCountersNilMap = errors.New("reset loss counters: nil map")
)

type LossCounters struct {
	KernelDrops    uint64
	ParserFailures uint64
}

func ReadLossCounters(losses *ebpf.Map) (LossCounters, error) {
	if losses == nil {
		return LossCounters{}, ErrReadLossCountersNilMap
	}

	counters := LossCounters{}
	if err := readLossCounter(losses, LossCounterKernelDrops, &counters.KernelDrops); err != nil {
		return LossCounters{}, err
	}
	if err := readLossCounter(losses, LossCounterParserFailures, &counters.ParserFailures); err != nil {
		return LossCounters{}, err
	}

	return counters, nil
}

func ResetLossCounters(losses *ebpf.Map) error {
	if losses == nil {
		return ErrResetLossCountersNilMap
	}

	var zero uint64
	for _, key := range []uint32{LossCounterKernelDrops, LossCounterParserFailures} {
		if err := losses.Update(&key, &zero, ebpf.UpdateAny); err != nil {
			return fmt.Errorf("reset loss counter %d: %w", key, err)
		}
	}

	return nil
}

func readLossCounter(losses *ebpf.Map, key uint32, value *uint64) error {
	if err := losses.Lookup(&key, value); err != nil {
		return fmt.Errorf("read loss counter %d: %w", key, err)
	}

	return nil
}
