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

package sweeper

import (
	"fmt"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

type buildStates struct {
	firstIP, firstAvailable, firstUnavailable, firstICMP, firstTCP bool
}

// scanBuilders holds string builders for different result categories
type scanBuilders struct {
	allIPs, availableIPs, unavailableIPs, icmp, tcp *strings.Builder
}

// initializeBuilders creates and pre-allocates string builders
func initializeBuilders(total int) *scanBuilders {
	builders := &scanBuilders{
		allIPs:         &strings.Builder{},
		availableIPs:   &strings.Builder{},
		unavailableIPs: &strings.Builder{},
		icmp:           &strings.Builder{},
		tcp:            &strings.Builder{},
	}

	// Pre-allocate builders with estimated capacity
	builders.allIPs.Grow(total * 13)
	builders.availableIPs.Grow(total * 13 / 2)
	builders.unavailableIPs.Grow(total * 13 / 2)
	builders.icmp.Grow(total * 60 / 2)
	builders.tcp.Grow(total * 60 / 2)

	return builders
}

// processIPLists builds IP lists based on availability
func processIPLists(result *models.Result, builders *scanBuilders, states *buildStates) {
	// Build all IPs list
	if !states.firstIP {
		builders.allIPs.WriteByte(',')
	}

	builders.allIPs.WriteString(result.Target.Host)

	if states.firstIP {
		states.firstIP = false
	}

	if result.Available {
		if !states.firstAvailable {
			builders.availableIPs.WriteByte(',')
		}

		builders.availableIPs.WriteString(result.Target.Host)

		if states.firstAvailable {
			states.firstAvailable = false
		}
	} else {
		if !states.firstUnavailable {
			builders.unavailableIPs.WriteByte(',')
		}

		builders.unavailableIPs.WriteString(result.Target.Host)

		if states.firstUnavailable {
			states.firstUnavailable = false
		}
	}
}

// processScanDetails builds detailed scan result strings
func processScanDetails(result *models.Result, builders *scanBuilders, states *buildStates) {
	switch result.Target.Mode {
	case models.ModeICMP:
		buildICMPDetails(result, builders.icmp, &states.firstICMP)
	case models.ModeTCP:
		buildTCPDetails(result, builders.tcp, &states.firstTCP)
	case models.ModeTCPConnect:
		buildTCPDetails(result, builders.tcp, &states.firstTCP)
	case models.ModeMTR:
		// MTR is handled by the agent's ad-hoc scan path and has no persistent
		// sweeper result detail.
	}
}

// buildScanDetails builds scan details for either ICMP or TCP
func buildScanDetails(result *models.Result, builder *strings.Builder, protocol string, firstFlag *bool) {
	if !*firstFlag {
		builder.WriteByte(';')
	}

	builder.WriteString(result.Target.Host)
	builder.WriteByte(':')
	builder.WriteString(protocol)
	builder.WriteString(":available=")

	if result.Available {
		builder.WriteString("true")
	} else {
		builder.WriteString("false")
	}

	builder.WriteString(":response_time=")
	builder.WriteString(result.RespTime.String())
	builder.WriteString(":packet_loss=")
	fmt.Fprintf(builder, "%.2f", result.PacketLoss)

	if *firstFlag {
		*firstFlag = false
	}
}

// buildICMPDetails builds ICMP scan details
func buildICMPDetails(result *models.Result, builder *strings.Builder, firstICMP *bool) {
	buildScanDetails(result, builder, "icmp", firstICMP)
}

// buildTCPDetails builds TCP scan details
func buildTCPDetails(result *models.Result, builder *strings.Builder, firstTCP *bool) {
	buildScanDetails(result, builder, scannerProtocolTCP, firstTCP)
}

// setBuiltMetadata assigns built strings to device metadata
func setBuiltMetadata(deviceUpdate *models.DeviceUpdate, builders *scanBuilders, total, availableCount int) {
	deviceUpdate.Metadata["scan_all_ips"] = builders.allIPs.String()
	deviceUpdate.Metadata["scan_available_ips"] = builders.availableIPs.String()
	deviceUpdate.Metadata["scan_unavailable_ips"] = builders.unavailableIPs.String()
	deviceUpdate.Metadata["scan_result_count"] = fmt.Sprintf("%d", total)
	deviceUpdate.Metadata["scan_available_count"] = fmt.Sprintf("%d", availableCount)
	deviceUpdate.Metadata["scan_unavailable_count"] = fmt.Sprintf("%d", total-availableCount)

	if builders.icmp.Len() > 0 {
		deviceUpdate.Metadata["scan_icmp_results"] = builders.icmp.String()
	}

	if builders.tcp.Len() > 0 {
		deviceUpdate.Metadata["scan_tcp_results"] = builders.tcp.String()
	}

	deviceUpdate.Metadata["scan_availability_percent"] = fmt.Sprintf("%.1f", float64(availableCount)/float64(total)*100)
	deviceUpdate.IsAvailable = availableCount > 0
}
