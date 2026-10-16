//go:build linux || darwin

/*
 * Copyright 2026 Carver Automation Corporation.
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

package mtr

// ipv4IHLMask and ipv4IHLUnit decode the IPv4 header length: the low nibble
// of the first byte, in 32-bit words.
const (
	ipv4IHLMask = 0x0f
	ipv4IHLUnit = 4
)

// ipv4HeaderLen is the header length an IPv4 packet's first byte declares.
func ipv4HeaderLen(firstByte byte) int {
	return int(firstByte&ipv4IHLMask) * ipv4IHLUnit
}
