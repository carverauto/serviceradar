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

package scan

import "errors"

var (
	errConnectionRefused = errors.New("connection refused")

	// IPv4/TCP parsing errors
	ErrShortIPv4Header     = errors.New("short IPv4 header")
	ErrNotIPv4             = errors.New("not IPv4")
	ErrBadIPv4HeaderLength = errors.New("bad IPv4 header length")
	ErrShortTCPHeader      = errors.New("short TCP header")
	ErrBadTCPHeaderLength  = errors.New("bad TCP header length")

	// Network errors
	ErrNonIPv4LocalIP     = errors.New("attachBPF: non-IPv4 local IP")
	ErrShortEthernet      = errors.New("short ethernet")
	ErrShortVLANHeader    = errors.New("short vlan header")
	ErrNonIPv4SourceIP    = errors.New("non-IPv4 source IP")
	ErrScanAlreadyRunning = errors.New("scan already running")
	ErrScanTimedOut       = errors.New("scan timed out")
	ErrPortClosed         = errors.New("port closed (RST)")

	// Interface errors
	ErrNoSuitableInterface = errors.New("no suitable local IP address and interface found")
	ErrInterfaceNotFound   = errors.New("could not find interface for local IP")
	ErrInterfaceNoIPv4     = errors.New("interface has no IPv4 address")
)
