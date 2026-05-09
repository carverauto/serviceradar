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
	"bytes"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/ebpf/probes"
)

const (
	enhancedSourceLinuxEBPF  = "linux_ebpf"
	enhancedBPFProbeCommand  = "command_execve"
	enhancedBPFCollectorName = "serviceradar_agent_ebpf"
)

func normalizeBPFCommandEvent(raw probes.CommandEvent, observedAt time.Time) EnhancedEvent {
	argc := int(raw.Argc)
	if argc > probes.CommandMaxArgs {
		argc = probes.CommandMaxArgs
	}
	if argc < 0 {
		argc = 0
	}

	argv := make([]string, 0, argc)
	for index := 0; index < argc; index++ {
		arg := cString(raw.Argv[index][:])
		if arg == "" {
			break
		}
		argv = append(argv, arg)
	}

	result := "ok"
	if raw.Result != 0 {
		result = strconv.Itoa(int(raw.Result))
	}

	return EnhancedEvent{
		EventType:         EnhancedEventCommand,
		TimestampUnixNano: observedAt.UnixNano(),
		PID:               int(raw.PID),
		UID:               int(raw.UID),
		GID:               int(raw.GID),
		CommandPath:       cString(raw.Path[:]),
		Argv:              argv,
		Result:            result,
		Metadata: map[string]string{
			"source":              enhancedSourceLinuxEBPF,
			"bpf":                 "true",
			"collector":           enhancedBPFCollectorName,
			"probe":               enhancedBPFProbeCommand,
			"kernel_timestamp_ns": strconv.FormatUint(raw.TimestampNS, 10),
			"tid":                 strconv.FormatUint(uint64(raw.TID), 10),
		},
	}
}

func cString(data []byte) string {
	if len(data) == 0 {
		return ""
	}
	if index := bytes.IndexByte(data, 0); index >= 0 {
		data = data[:index]
	}
	return string(data)
}
