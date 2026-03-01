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

package mtr

import "time"

// Protocol represents the probe protocol used for MTR traces.
type Protocol int

const (
	// ProtocolICMP uses ICMP Echo Request probes.
	ProtocolICMP Protocol = iota
	// ProtocolUDP uses UDP probes with incrementing destination ports.
	ProtocolUDP
	// ProtocolTCP uses TCP SYN probes.
	ProtocolTCP
)

// String returns the string representation of a Protocol.
func (p Protocol) String() string {
	switch p {
	case ProtocolICMP:
		return "icmp"
	case ProtocolUDP:
		return "udp"
	case ProtocolTCP:
		return "tcp"
	default:
		return "unknown"
	}
}

// ParseProtocol converts a string to a Protocol.
func ParseProtocol(s string) Protocol {
	switch s {
	case "udp":
		return ProtocolUDP
	case "tcp":
		return ProtocolTCP
	default:
		return ProtocolICMP
	}
}

const (
	DefaultMaxHops         = 30
	DefaultProbesPerHop    = 10
	DefaultProbeIntervalMs = 100
	DefaultPacketSize      = 64
	DefaultTimeout         = 5 * time.Second
	DefaultTraceInterval   = 5 * time.Minute
	DefaultMaxUnknownHops  = 10
	DefaultUDPBasePort     = 33434
	DefaultASNDBPath       = "/usr/share/GeoIP/GeoLite2-ASN.mmdb"
	DefaultRingBufferSize  = 200

	// MinPort is the minimum port used for probe sequence encoding.
	MinPort = 33434
	// MaxPort is the maximum port for sequence space.
	MaxPort = 65535
)

// Options configures an MTR trace.
type Options struct {
	// Target is the destination host (IP or hostname).
	Target string

	// MaxHops is the maximum TTL value (number of hops to probe).
	MaxHops int

	// ProbesPerHop is the number of probes to send per hop per cycle.
	ProbesPerHop int

	// Protocol is the probe protocol (ICMP, UDP, TCP).
	Protocol Protocol

	// Timeout is the maximum time to wait for a probe response.
	Timeout time.Duration

	// ProbeInterval is the delay between sending individual probes.
	ProbeInterval time.Duration

	// PacketSize is the total IP packet size in bytes.
	PacketSize int

	// DNSResolve enables async reverse DNS resolution for hop IPs.
	DNSResolve bool

	// ASNDBPath is the path to GeoLite2-ASN.mmdb for ASN enrichment.
	ASNDBPath string

	// MaxUnknownHops is the number of consecutive non-responding hops
	// before the trace terminates.
	MaxUnknownHops int

	// RingBufferSize is the number of RTT samples to keep per hop
	// for sparkline/histogram data.
	RingBufferSize int

	// SrcAddr optionally sets the source address for probes.
	SrcAddr string
}

// DefaultOptions returns Options with sensible defaults.
func DefaultOptions(target string) Options {
	return Options{
		Target:         target,
		MaxHops:        DefaultMaxHops,
		ProbesPerHop:   DefaultProbesPerHop,
		Protocol:       ProtocolICMP,
		Timeout:        DefaultTimeout,
		ProbeInterval:  time.Duration(DefaultProbeIntervalMs) * time.Millisecond,
		PacketSize:     DefaultPacketSize,
		DNSResolve:     true,
		ASNDBPath:      DefaultASNDBPath,
		MaxUnknownHops: DefaultMaxUnknownHops,
		RingBufferSize: DefaultRingBufferSize,
	}
}
