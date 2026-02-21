package fastsum

import "syscall"

// Fold32 folds a 32-bit partial sum to 16 bits and returns the 1's complement.
func Fold32(sum uint32) uint16 {
	// End-around carry fold to 16 bits
	s := sum
	s = (s & 0xFFFF) + (s >> 16)
	s = (s & 0xFFFF) + (s >> 16)
	// #nosec G115 - Truncation is intentional for checksum calculation
	return ^uint16(s)
}

// Checksum computes the Internet checksum (1's complement) over b.
func Checksum(b []byte) uint16 {
	return Fold32(SumBE16(b))
}

// TCPv4 computes the TCP checksum (IPv4 pseudo-header + TCP header + payload).
// The TCP header's checksum field must be zeroed by the caller.
func TCPv4(src, dst [4]byte, tcpHdr, payload []byte) uint16 {
	var sum uint32

	// IPv4 pseudo-header: src, dst, protocol, TCP len
	sum += uint32(src[0])<<8 | uint32(src[1])
	sum += uint32(src[2])<<8 | uint32(src[3])
	sum += uint32(dst[0])<<8 | uint32(dst[1])
	sum += uint32(dst[2])<<8 | uint32(dst[3])
	sum += uint32(syscall.IPPROTO_TCP)
	tcpLen := len(tcpHdr) + len(payload)
	// #nosec G115 - Truncation is intentional for checksum calculation
	sum += uint32(uint16(tcpLen)) // big-endian numeric is the same value

	// TCP header + payload
	sum += SumBE16(tcpHdr)
	if len(payload) != 0 {
		sum += SumBE16(payload)
	}

	return Fold32(sum)
}
