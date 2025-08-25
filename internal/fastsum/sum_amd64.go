//go:build linux && amd64
// +build linux,amd64

package fastsum

//go:noescape
func sumBE16Ptr(p *byte, n int) uint32

// SumBE16 returns the (unfolded) one's-complement sum of 16-bit big-endian
// words over b. Odd last byte (if any) is treated as high-order byte.
func SumBE16(b []byte) uint32 {
    if len(b) == 0 {
        return 0
    }
    return sumBE16Ptr(&b[0], len(b))
}

