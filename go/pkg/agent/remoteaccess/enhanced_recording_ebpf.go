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
	"encoding/binary"
	"net/netip"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/ebpf/probes"
)

const (
	enhancedSourceLinuxEBPF  = "linux_ebpf"
	enhancedBPFProbeCommand  = "command_execve"
	enhancedBPFProbeFile     = "file_open_access"
	enhancedBPFProbeNetwork  = "network_connect"
	enhancedBPFCollectorName = "serviceradar_agent_ebpf"
	enhancedMetadataTrue     = "true"
	enhancedMetadataFalse    = "false"
	enhancedMetadataRedacted = "REDACTED"
)

func normalizeBPFCommandEvent(raw probes.CommandEvent, observedAt time.Time) EnhancedEvent {
	argc := probes.CommandMaxArgs
	if raw.Argc <= uint32(probes.CommandMaxArgs) {
		argc = int(raw.Argc)
	}

	argv := make([]string, 0, argc)
	for index := 0; index < argc; index++ {
		arg := sanitizeKernelCString(raw.Argv[index][:])
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
		CommandPath:       sanitizeKernelCString(raw.Path[:]),
		Argv:              argv,
		Result:            result,
		Metadata: map[string]string{
			"source":              enhancedSourceLinuxEBPF,
			"bpf":                 enhancedMetadataTrue,
			"collector":           enhancedBPFCollectorName,
			"probe":               enhancedBPFProbeCommand,
			"kernel_timestamp_ns": strconv.FormatUint(raw.TimestampNS, 10),
			"tid":                 strconv.FormatUint(uint64(raw.TID), 10),
		},
	}
}

func normalizeBPFFileEvent(raw probes.FileEvent, observedAt time.Time) EnhancedEvent {
	result := "ok"
	if raw.Result != 0 {
		result = strconv.Itoa(int(raw.Result))
	}

	return EnhancedEvent{
		EventType:         EnhancedEventFile,
		TimestampUnixNano: observedAt.UnixNano(),
		PID:               int(raw.PID),
		UID:               int(raw.UID),
		GID:               int(raw.GID),
		FilePath:          sanitizeKernelCString(raw.Path[:]),
		FileOperation:     bpfFileOperation(raw.Operation),
		Result:            result,
		Metadata: map[string]string{
			"source":              enhancedSourceLinuxEBPF,
			"bpf":                 enhancedMetadataTrue,
			"collector":           enhancedBPFCollectorName,
			"probe":               enhancedBPFProbeFile,
			"kernel_timestamp_ns": strconv.FormatUint(raw.TimestampNS, 10),
			"tid":                 strconv.FormatUint(uint64(raw.TID), 10),
			"flags":               strconv.FormatUint(uint64(raw.Flags), 10),
		},
	}
}

func normalizeBPFNetworkEvent(raw probes.NetworkEvent, observedAt time.Time) EnhancedEvent {
	result := "ok"
	if raw.Result != 0 {
		result = strconv.Itoa(int(raw.Result))
	}

	return EnhancedEvent{
		EventType:          EnhancedEventNetwork,
		TimestampUnixNano:  observedAt.UnixNano(),
		PID:                int(raw.PID),
		UID:                int(raw.UID),
		GID:                int(raw.GID),
		NetworkProtocol:    "connect",
		DestinationAddress: bpfNetworkAddress(raw),
		DestinationPort:    int(binary.BigEndian.Uint16(raw.DestPort[:])),
		Result:             result,
		Metadata: map[string]string{
			"source":              enhancedSourceLinuxEBPF,
			"bpf":                 enhancedMetadataTrue,
			"collector":           enhancedBPFCollectorName,
			"probe":               enhancedBPFProbeNetwork,
			"kernel_timestamp_ns": strconv.FormatUint(raw.TimestampNS, 10),
			"tid":                 strconv.FormatUint(uint64(raw.TID), 10),
			"family":              strconv.FormatUint(uint64(raw.Family), 10),
			"addr_len":            strconv.FormatUint(uint64(raw.AddrLen), 10),
			"syscall":             "connect",
		},
	}
}

func bpfFileOperation(operation uint32) string {
	switch operation {
	case probes.FileOperationOpen:
		return "open"
	case probes.FileOperationAccess:
		return "access"
	default:
		return "unknown"
	}
}

func bpfNetworkAddress(raw probes.NetworkEvent) string {
	switch raw.Family {
	case probes.AddressFamilyIPv4:
		var addr [4]byte

		copy(addr[:], raw.DestAddr[:4])

		return netip.AddrFrom4(addr).String()
	case probes.AddressFamilyIPv6:
		var addr [16]byte

		copy(addr[:], raw.DestAddr[:])

		return netip.AddrFrom16(addr).String()
	default:
		return ""
	}
}
