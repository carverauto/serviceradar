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

package mapper

import (
	"fmt"
)

func formatMACAddress(mac []byte) string {
	if len(mac) != defaultByteLength {
		return ""
	}

	return fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x",
		mac[0], mac[1], mac[2], mac[3], mac[4], mac[5])
}

func usableMACFromPDUValue(value interface{}) string {
	bytes, ok := value.([]byte)
	if !ok {
		return ""
	}

	formatted := formatMACAddress(bytes)
	if !usableHardwareMAC(formatted) {
		return ""
	}

	return formatted
}

const (
	defaultByteLength = 6
)

// formatLLDPID formats LLDP identifiers which may be MAC addresses or other formats
func formatLLDPID(bytes []byte) string {
	// Check if it looks like a MAC address (common for chassis ID)
	if len(bytes) == defaultByteLength {
		return formatMACAddress(bytes)
	}

	// If it's a printable string, return as is
	return string(bytes)
}
