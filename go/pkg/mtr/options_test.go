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

import "testing"

func TestProtocol_String(t *testing.T) {
	t.Parallel()

	tests := []struct {
		proto Protocol
		want  string
	}{
		{ProtocolICMP, "icmp"},
		{ProtocolUDP, "udp"},
		{ProtocolTCP, "tcp"},
		{Protocol(99), "unknown"},
	}

	for _, tt := range tests {
		if got := tt.proto.String(); got != tt.want {
			t.Errorf("Protocol(%d).String() = %q, want %q", tt.proto, got, tt.want)
		}
	}
}

func TestParseProtocol(t *testing.T) {
	t.Parallel()

	tests := []struct {
		input string
		want  Protocol
	}{
		{"icmp", ProtocolICMP},
		{"udp", ProtocolUDP},
		{"tcp", ProtocolTCP},
		{"", ProtocolICMP},
		{"garbage", ProtocolICMP},
	}

	for _, tt := range tests {
		if got := ParseProtocol(tt.input); got != tt.want {
			t.Errorf("ParseProtocol(%q) = %d, want %d", tt.input, got, tt.want)
		}
	}
}

func TestDefaultOptions(t *testing.T) {
	t.Parallel()

	opts := DefaultOptions("example.com")

	if opts.Target != "example.com" {
		t.Errorf("Target = %q, want example.com", opts.Target)
	}

	if opts.MaxHops != DefaultMaxHops {
		t.Errorf("MaxHops = %d, want %d", opts.MaxHops, DefaultMaxHops)
	}

	if opts.ProbesPerHop != DefaultProbesPerHop {
		t.Errorf("ProbesPerHop = %d, want %d", opts.ProbesPerHop, DefaultProbesPerHop)
	}

	if opts.Protocol != ProtocolICMP {
		t.Errorf("Protocol = %d, want ProtocolICMP", opts.Protocol)
	}

	if !opts.DNSResolve {
		t.Error("DNSResolve should default to true")
	}
}
