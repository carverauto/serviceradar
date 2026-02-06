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
	"time"

	"github.com/miekg/dns"
	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/pkg/logger"
	mdnspb "github.com/carverauto/serviceradar/proto/mdns"
)

// Listener listens for mDNS multicast packets and sends parsed protobuf records
// to a channel for publishing.
type Listener struct {
	config *Config
	dedup  *DedupCache
	ch     chan<- []byte
	conn   *net.UDPConn
	logger logger.Logger
}

// NewListener creates a new mDNS multicast listener.
func NewListener(config *Config, dedup *DedupCache, ch chan<- []byte, log logger.Logger) *Listener {
	return &Listener{
		config: config,
		dedup:  dedup,
		ch:     ch,
		logger: log,
	}
}

// Start binds the UDP multicast socket and joins multicast groups.
func (l *Listener) Start() error {
	addr, err := net.ResolveUDPAddr("udp4", l.config.ListenAddr)
	if err != nil {
		return err
	}

	conn, err := net.ListenMulticastUDP("udp4", l.resolveInterface(), addr)
	if err != nil {
		return err
	}

	if err := conn.SetReadBuffer(l.config.BufferSize); err != nil {
		l.logger.Warn().Err(err).Msg("Failed to set UDP read buffer size")
	}

	l.conn = conn
	l.logger.Info().
		Str("addr", l.config.ListenAddr).
		Strs("groups", l.config.MulticastGroups).
		Msg("mDNS listener started")

	return nil
}

// Run reads packets in a loop until the connection is closed.
func (l *Listener) Run() {
	buf := make([]byte, l.config.BufferSize)

	for {
		n, remoteAddr, err := l.conn.ReadFromUDP(buf)
		if err != nil {
			// Check if the connection was closed (expected during shutdown)
			if opErr, ok := err.(*net.OpError); ok && opErr.Err.Error() == "use of closed network connection" {
				l.logger.Info().Msg("mDNS listener connection closed")
				return
			}
			l.logger.Error().Err(err).Msg("Error receiving mDNS UDP packet")
			continue
		}

		l.processPacket(buf[:n], remoteAddr)
	}
}

// Close closes the underlying UDP connection.
func (l *Listener) Close() error {
	if l.conn != nil {
		return l.conn.Close()
	}
	return nil
}

func (l *Listener) resolveInterface() *net.Interface {
	if l.config.ListenInterface == "" {
		return nil
	}
	iface, err := net.InterfaceByName(l.config.ListenInterface)
	if err != nil {
		l.logger.Warn().Err(err).Str("interface", l.config.ListenInterface).Msg("Failed to resolve interface, using default")
		return nil
	}
	return iface
}

func (l *Listener) processPacket(data []byte, remoteAddr *net.UDPAddr) {
	var msg dns.Msg
	if err := msg.Unpack(data); err != nil {
		l.logger.Debug().Err(err).Msg("Failed to parse DNS packet")
		return
	}

	// Only process responses (QR bit set)
	if !msg.Response {
		return
	}

	receiveTimeNs := uint64(time.Now().UnixNano())
	sourceIP := ipToBytes(remoteAddr.IP)

	// Process answers and additional records
	allRRs := append(msg.Answer, msg.Extra...)
	for _, rr := range allRRs {
		records := l.rrToRecords(rr, sourceIP, receiveTimeNs)
		for _, record := range records {
			if !l.dedup.CheckAndInsert(record.Hostname, record.ResolvedAddr) {
				continue
			}

			encoded, err := proto.Marshal(record)
			if err != nil {
				l.logger.Error().Err(err).Msg("Failed to encode mDNS protobuf")
				continue
			}

			select {
			case l.ch <- encoded:
			default:
				l.logger.Warn().Msg("Publisher channel full, dropping mDNS record")
			}
		}
	}
}

func (l *Listener) rrToRecords(rr dns.RR, sourceIP []byte, receiveTimeNs uint64) []*mdnspb.MdnsRecord {
	header := rr.Header()
	dnsName := header.Name
	dnsTTL := header.Ttl

	switch v := rr.(type) {
	case *dns.A:
		ip := v.A.To4()
		if ip == nil {
			return nil
		}
		return []*mdnspb.MdnsRecord{{
			RecordType:      mdnspb.MdnsRecord_A,
			TimeReceivedNs:  receiveTimeNs,
			SourceIp:        sourceIP,
			Hostname:        dnsName,
			ResolvedAddr:    []byte(ip),
			ResolvedAddrStr: v.A.String(),
			DnsTtl:          dnsTTL,
			DnsName:         dnsName,
			IsResponse:      true,
		}}
	case *dns.AAAA:
		ip := v.AAAA
		if ip == nil {
			return nil
		}
		return []*mdnspb.MdnsRecord{{
			RecordType:      mdnspb.MdnsRecord_AAAA,
			TimeReceivedNs:  receiveTimeNs,
			SourceIp:        sourceIP,
			Hostname:        dnsName,
			ResolvedAddr:    []byte(ip.To16()),
			ResolvedAddrStr: ip.String(),
			DnsTtl:          dnsTTL,
			DnsName:         dnsName,
			IsResponse:      true,
		}}
	case *dns.PTR:
		return []*mdnspb.MdnsRecord{{
			RecordType:      mdnspb.MdnsRecord_PTR,
			TimeReceivedNs:  receiveTimeNs,
			SourceIp:        sourceIP,
			Hostname:        v.Ptr,
			ResolvedAddr:    nil,
			ResolvedAddrStr: "",
			DnsTtl:          dnsTTL,
			DnsName:         dnsName,
			IsResponse:      true,
		}}
	default:
		return nil
	}
}

// ipToBytes converts a net.IP to its byte representation.
func ipToBytes(ip net.IP) []byte {
	if v4 := ip.To4(); v4 != nil {
		return []byte(v4)
	}
	return []byte(ip.To16())
}

// ParseMdnsPacket parses a raw DNS packet and extracts mDNS records.
// Exported for testing.
func ParseMdnsPacket(data []byte, sourceIP net.IP, receiveTimeNs uint64) []*mdnspb.MdnsRecord {
	var msg dns.Msg
	if err := msg.Unpack(data); err != nil {
		return nil
	}

	if !msg.Response {
		return nil
	}

	srcBytes := ipToBytes(sourceIP)
	var records []*mdnspb.MdnsRecord

	allRRs := append(msg.Answer, msg.Extra...)
	for _, rr := range allRRs {
		parsed := rrToRecordsStatic(rr, srcBytes, receiveTimeNs)
		records = append(records, parsed...)
	}

	return records
}

// rrToRecordsStatic is a static version for use in ParseMdnsPacket.
func rrToRecordsStatic(rr dns.RR, sourceIP []byte, receiveTimeNs uint64) []*mdnspb.MdnsRecord {
	header := rr.Header()
	dnsName := header.Name
	dnsTTL := header.Ttl

	switch v := rr.(type) {
	case *dns.A:
		ip := v.A.To4()
		if ip == nil {
			return nil
		}
		return []*mdnspb.MdnsRecord{{
			RecordType:      mdnspb.MdnsRecord_A,
			TimeReceivedNs:  receiveTimeNs,
			SourceIp:        sourceIP,
			Hostname:        dnsName,
			ResolvedAddr:    []byte(ip),
			ResolvedAddrStr: v.A.String(),
			DnsTtl:          dnsTTL,
			DnsName:         dnsName,
			IsResponse:      true,
		}}
	case *dns.AAAA:
		ip := v.AAAA
		if ip == nil {
			return nil
		}
		return []*mdnspb.MdnsRecord{{
			RecordType:      mdnspb.MdnsRecord_AAAA,
			TimeReceivedNs:  receiveTimeNs,
			SourceIp:        sourceIP,
			Hostname:        dnsName,
			ResolvedAddr:    []byte(ip.To16()),
			ResolvedAddrStr: ip.String(),
			DnsTtl:          dnsTTL,
			DnsName:         dnsName,
			IsResponse:      true,
		}}
	case *dns.PTR:
		return []*mdnspb.MdnsRecord{{
			RecordType:      mdnspb.MdnsRecord_PTR,
			TimeReceivedNs:  receiveTimeNs,
			SourceIp:        sourceIP,
			Hostname:        v.Ptr,
			ResolvedAddr:    nil,
			ResolvedAddrStr: "",
			DnsTtl:          dnsTTL,
			DnsName:         dnsName,
			IsResponse:      true,
		}}
	default:
		return nil
	}
}
