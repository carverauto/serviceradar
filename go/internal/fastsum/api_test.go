package fastsum_test

import (
	"encoding/binary"
	"syscall"
	"testing"

	"github.com/carverauto/serviceradar/go/internal/fastsum"
)

func TestTCPv6MatchesReference(t *testing.T) {
	t.Parallel()

	src := [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10}
	dst := [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20}
	tcpHdr := []byte{
		0x9c, 0x40, // source port 40000
		0x01, 0xbb, // destination port 443
		0x10, 0x20, 0x30, 0x40, // sequence
		0x00, 0x00, 0x00, 0x00, // ack
		0x50, 0x02, // data offset + SYN
		0xff, 0xff, // window
		0x00, 0x00, // checksum
		0x00, 0x00, // urgent pointer
	}
	payload := []byte{0x01, 0x02, 0x03}

	got := fastsum.TCPv6(src, dst, tcpHdr, payload)
	want := refTCPv6(src, dst, tcpHdr, payload)
	if got != want {
		t.Fatalf("TCPv6 checksum = %#04x, want %#04x", got, want)
	}

	withChecksum := append([]byte(nil), tcpHdr...)
	binary.BigEndian.PutUint16(withChecksum[16:], got)
	if verify := refTCPv6(src, dst, withChecksum, payload); verify != 0 {
		t.Fatalf("TCPv6 checksum verification = %#04x, want 0", verify)
	}
}

func refTCPv6(src, dst [16]byte, tcpHdr, payload []byte) uint16 {
	sum := refSumBE16(src[:]) + refSumBE16(dst[:])
	tcpLen := len(tcpHdr) + len(payload)
	sum += uint32(uint16(tcpLen >> 16))
	sum += uint32(uint16(tcpLen))
	sum += uint32(syscall.IPPROTO_TCP)
	sum += refSumBE16(tcpHdr)
	sum += refSumBE16(payload)

	return refFold32(sum)
}

func refSumBE16(b []byte) uint32 {
	var sum uint32
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}

	return sum
}

func refFold32(sum uint32) uint16 {
	sum = (sum & 0xffff) + (sum >> 16)
	sum = (sum & 0xffff) + (sum >> 16)

	return ^uint16(sum)
}
