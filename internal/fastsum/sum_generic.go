//go:build !(linux && amd64) && !(linux && arm64)
// +build !linux
// +build !amd64,!arm64

package fastsum

// SumBE16 (portable fallback) – still much faster than BigEndian.Uint16 in a loop.
func SumBE16(b []byte) uint32 {
    var sum uint32
    i := 0
    n := len(b)

    // Unroll a bit for speed
    for n >= 8 {
        sum += uint32(b[i])<<8 | uint32(b[i+1])
        sum += uint32(b[i+2])<<8 | uint32(b[i+3])
        sum += uint32(b[i+4])<<8 | uint32(b[i+5])
        sum += uint32(b[i+6])<<8 | uint32(b[i+7])
        i += 8
        n -= 8
    }
    for n >= 2 {
        sum += uint32(b[i])<<8 | uint32(b[i+1])
        i += 2
        n -= 2
    }
    if n == 1 {
        sum += uint32(b[i]) << 8
    }
    return sum
}
