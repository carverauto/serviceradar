package mtr

import (
	"encoding/binary"
	"testing"
)

func TestICMPResponseReleaseClearsPooledPayload(t *testing.T) {
	t.Parallel()

	pool := newRecvBufferPool()
	buf := pool.get(defaultRecvBufferSize)
	resp := &ICMPResponse{
		Payload:  buf[:32],
		recvBuf:  buf,
		recvPool: &pool,
	}

	resp.Release()

	if resp.recvBuf != nil {
		t.Fatal("expected receive buffer to be released")
	}
	if resp.Payload != nil {
		t.Fatal("expected payload slice to be cleared after release")
	}
}

func TestPrepareICMPEchoPacket_IPv4(t *testing.T) {
	t.Parallel()

	packet := prepareICMPEchoPacket(nil, []byte{0xAA, 0xBB}, 0x1234, 0x5678, false)

	if len(packet) != 10 {
		t.Fatalf("expected packet length 10, got %d", len(packet))
	}
	if packet[0] != 8 {
		t.Fatalf("expected IPv4 echo request type 8, got %d", packet[0])
	}
	if binary.BigEndian.Uint16(packet[4:6]) != 0x1234 {
		t.Fatalf("expected id 0x1234, got 0x%X", binary.BigEndian.Uint16(packet[4:6]))
	}
	if binary.BigEndian.Uint16(packet[6:8]) != 0x5678 {
		t.Fatalf("expected seq 0x5678, got 0x%X", binary.BigEndian.Uint16(packet[6:8]))
	}
	if packet[8] != 0xAA || packet[9] != 0xBB {
		t.Fatalf("expected payload bytes to be copied, got %#v", packet[8:])
	}
	if checksum(packet) != 0 {
		t.Fatalf("expected finalized IPv4 packet checksum to validate, got 0x%X", checksum(packet))
	}
}

func TestPrepareICMPEchoPacket_IPv6(t *testing.T) {
	t.Parallel()

	packet := prepareICMPEchoPacket(nil, []byte{0xCC}, 0x0102, 0x0304, true)

	if len(packet) != 9 {
		t.Fatalf("expected packet length 9, got %d", len(packet))
	}
	if packet[0] != 128 {
		t.Fatalf("expected IPv6 echo request type 128, got %d", packet[0])
	}
	if binary.BigEndian.Uint16(packet[2:4]) != 0 {
		t.Fatalf("expected IPv6 checksum field to remain zero, got 0x%X", binary.BigEndian.Uint16(packet[2:4]))
	}
	if binary.BigEndian.Uint16(packet[4:6]) != 0x0102 {
		t.Fatalf("expected id 0x0102, got 0x%X", binary.BigEndian.Uint16(packet[4:6]))
	}
	if binary.BigEndian.Uint16(packet[6:8]) != 0x0304 {
		t.Fatalf("expected seq 0x0304, got 0x%X", binary.BigEndian.Uint16(packet[6:8]))
	}
	if packet[8] != 0xCC {
		t.Fatalf("expected payload byte to be copied, got %#v", packet[8:])
	}
}
