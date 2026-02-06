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

package mdns

import (
	"net"
	"testing"

	"github.com/miekg/dns"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// buildResponsePacket constructs a DNS response packet with the given answer records.
func buildResponsePacket(answers []dns.RR) []byte {
	msg := new(dns.Msg)
	msg.Id = 0
	msg.Response = true
	msg.Authoritative = true
	msg.Answer = answers
	data, _ := msg.Pack()
	return data
}

// buildQueryPacket constructs a DNS query packet.
func buildQueryPacket() []byte {
	msg := new(dns.Msg)
	msg.Id = 0
	msg.Response = false
	msg.Question = []dns.Question{
		{Name: "_http._tcp.local.", Qtype: dns.TypePTR, Qclass: dns.ClassINET},
	}
	data, _ := msg.Pack()
	return data
}

func TestParseARecord(t *testing.T) {
	t.Parallel()

	rr := &dns.A{
		Hdr: dns.RR_Header{Name: "mydevice.local.", Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 120},
		A:   net.IPv4(192, 168, 1, 42),
	}
	data := buildResponsePacket([]dns.RR{rr})
	source := net.IPv4(192, 168, 1, 42)
	records := ParseMdnsPacket(data, source, 1_000_000_000)

	require.Len(t, records, 1)
	assert.Equal(t, "A", records[0].RecordType)
	assert.Equal(t, "mydevice.local.", records[0].Hostname)
	assert.Equal(t, "192.168.1.42", records[0].ResolvedAddr)
	assert.Equal(t, uint32(120), records[0].DnsTTL)
	assert.True(t, records[0].IsResponse)
}

func TestParseAAAARecord(t *testing.T) {
	t.Parallel()

	addr := net.ParseIP("fe80::1")
	rr := &dns.AAAA{
		Hdr:  dns.RR_Header{Name: "mydevice.local.", Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: 120},
		AAAA: addr,
	}
	data := buildResponsePacket([]dns.RR{rr})
	source := net.IPv4(192, 168, 1, 42)
	records := ParseMdnsPacket(data, source, 1_000_000_000)

	require.Len(t, records, 1)
	assert.Equal(t, "AAAA", records[0].RecordType)
	assert.Equal(t, "mydevice.local.", records[0].Hostname)
	assert.Equal(t, "fe80::1", records[0].ResolvedAddr)
}

func TestParsePTRRecord(t *testing.T) {
	t.Parallel()

	rr := &dns.PTR{
		Hdr: dns.RR_Header{Name: "_http._tcp.local.", Rrtype: dns.TypePTR, Class: dns.ClassINET, Ttl: 4500},
		Ptr: "mywebserver._http._tcp.local.",
	}
	data := buildResponsePacket([]dns.RR{rr})
	source := net.IPv4(192, 168, 1, 10)
	records := ParseMdnsPacket(data, source, 2_000_000_000)

	require.Len(t, records, 1)
	assert.Equal(t, "PTR", records[0].RecordType)
	assert.Equal(t, "mywebserver._http._tcp.local.", records[0].Hostname)
	assert.Equal(t, "_http._tcp.local.", records[0].DnsName)
	assert.Empty(t, records[0].ResolvedAddr)
	assert.Equal(t, uint32(4500), records[0].DnsTTL)
}

func TestIgnoresQueries(t *testing.T) {
	t.Parallel()

	data := buildQueryPacket()
	source := net.IPv4(192, 168, 1, 10)
	records := ParseMdnsPacket(data, source, 1_000_000_000)
	assert.Empty(t, records)
}

func TestMultipleRecords(t *testing.T) {
	t.Parallel()

	rrA := &dns.A{
		Hdr: dns.RR_Header{Name: "device-a.local.", Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 120},
		A:   net.IPv4(10, 0, 0, 1),
	}
	rrPTR := &dns.PTR{
		Hdr: dns.RR_Header{Name: "_tcp.local.", Rrtype: dns.TypePTR, Class: dns.ClassINET, Ttl: 300},
		Ptr: "device-a._tcp.local.",
	}
	data := buildResponsePacket([]dns.RR{rrA, rrPTR})
	source := net.IPv4(10, 0, 0, 1)
	records := ParseMdnsPacket(data, source, 1_000_000_000)

	require.Len(t, records, 2)
	assert.Equal(t, "A", records[0].RecordType)
	assert.Equal(t, "PTR", records[1].RecordType)
}

func TestInvalidPacket(t *testing.T) {
	t.Parallel()

	records := ParseMdnsPacket([]byte{0xff, 0xff, 0xff}, net.IPv4(10, 0, 0, 1), 1_000_000_000)
	assert.Empty(t, records)
}

func TestSourceIPString(t *testing.T) {
	t.Parallel()

	rr := &dns.A{
		Hdr: dns.RR_Header{Name: "test.local.", Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60},
		A:   net.IPv4(10, 0, 0, 5),
	}
	data := buildResponsePacket([]dns.RR{rr})
	source := net.IPv4(192, 168, 1, 100)
	records := ParseMdnsPacket(data, source, 1_000_000_000)

	require.Len(t, records, 1)
	assert.Equal(t, "192.168.1.100", records[0].SourceIP)
}
