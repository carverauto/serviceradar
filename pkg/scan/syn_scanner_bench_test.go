//go:build linux
// +build linux

package scan

import (
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// buildSYNACKFrame fabricates an Ethernet+IPv4+TCP SYN/ACK frame addressed to localIP
// and destined to dstPort (which should match the scanner's srcPort mapping).
func buildSYNACKFrame(localIP, remoteIP net.IP, dstPort, srcPort uint16) []byte {
	eth := make([]byte, 14)
	// dst/src MAC left zeroed (not parsed by scanner)
	binary.BigEndian.PutUint16(eth[12:], 0x0800)

	ip := make([]byte, 20)
	ip[0] = 0x45
	ip[1] = 0
	binary.BigEndian.PutUint16(ip[2:], 40)
	binary.BigEndian.PutUint16(ip[4:], 0x1234)
	binary.BigEndian.PutUint16(ip[6:], 0)
	ip[8] = 64
	ip[9] = 6 // TCP
	copy(ip[12:16], remoteIP.To4())
	copy(ip[16:20], localIP.To4())
	binary.BigEndian.PutUint16(ip[10:], ChecksumNew(ip))

	tcp := make([]byte, 20)
	binary.BigEndian.PutUint16(tcp[0:], srcPort) // remote's src = target's dst
	binary.BigEndian.PutUint16(tcp[2:], dstPort) // reply dst = our ephemeral src
	binary.BigEndian.PutUint32(tcp[4:], 0xABCDEF01)
	binary.BigEndian.PutUint32(tcp[8:], 0)
	tcp[12] = 5 << 4
	tcp[13] = synFlag | ackFlag
	binary.BigEndian.PutUint16(tcp[14:], defaultTCPWindow)
	binary.BigEndian.PutUint16(tcp[16:], 0)
	binary.BigEndian.PutUint16(tcp[18:], 0)
	binary.BigEndian.PutUint16(tcp[16:], tcpChecksumNew(remoteIP, localIP, tcp, nil))

	return append(eth, append(ip, tcp...)...)
}

func BenchmarkProcessEthernetFrame(b *testing.B) {
	// Minimal scanner with pre-wired maps.
	s := &SYNScanner{}
	local := net.IPv4(192, 0, 2, 10)
	remote := net.IPv4(198, 51, 100, 20)
	ourSrc := uint16(40000)
	targetPort := 443
	key := remote.String() + ":" + "443"

	s.mu.Lock()
	s.portTargetMap = map[uint16]string{ourSrc: key}
	s.targetIP = map[string]string{key: remote.String()}
	s.results = map[string]models.Result{key: {
		Target:    models.Target{Host: remote.String(), Port: targetPort, Mode: models.ModeTCP},
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}}
	s.mu.Unlock()

	frame := buildSYNACKFrame(local, remote, ourSrc, uint16(targetPort))

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s.processEthernetFrame(frame)
	}
}
